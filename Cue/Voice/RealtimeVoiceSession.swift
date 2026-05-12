import Foundation
import AVFoundation
import Combine
import WebRTC
import os

private let log = Logger(subsystem: "com.toug.cue", category: "RealtimeVoice")

/// One OpenAI Realtime voice conversation, end-to-end.
///
/// Lifecycle:
///   1. `start(context:)` → mint ephemeral token + assemble transcript
///      context via `CueAPI.requestVoiceSession`.
///   2. Set up `RTCPeerConnection` with a mic track + a data channel
///      named `"oai-events"`. SDP-exchange with
///      `https://api.openai.com/v1/realtime/calls` using the ephemeral
///      token as the Bearer.
///   3. When the data channel opens, send the `[Episode context — last
///      5 min …]` user message as a `conversation.item.create` so the
///      model has the rolling transcript.
///   4. Parse inbound data-channel events (speech_started, transcript
///      deltas, function_call) and drive `@Published` state for the UI.
///   5. Tool calls dispatch to `RealtimeTools.dispatch(...)`. Playback
///      tools (resume / seek / rewind) are terminal — after sending the
///      `function_call_output` we tear down and let
///      `AppState.resumeAfterVoice()` restart the podcast + wake engine.
///   6. `stop()` (or an `AVAudioSession.interruptionNotification`) closes
///      the peer connection cleanly and restores the podcast's audio
///      session config.
///
/// Mirrors voice-ai-playground/lib/providers/openai-realtime/client.ts
/// but translated to stasel/WebRTC's Swift API.
@MainActor
final class RealtimeVoiceSession: NSObject, ObservableObject {
    enum Phase: String, Equatable {
        case idle, connecting, listening, thinking, speaking, ended, error
    }

    struct Context {
        let audioUrl: String
        let pausedAtSeconds: Double
        let totalDurationSeconds: Double?
        let episodeTitle: String
        let showTitle: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var userTranscript: String = ""
    @Published private(set) var assistantTranscript: String = ""
    @Published private(set) var errorMessage: String?

    private let api: CueAPI
    private weak var state: AppState?

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var pendingContextMessage: String?
    private var interruptionObserver: NSObjectProtocol?

    /// RTCInitializeSSL must be called exactly once per process. This
    /// static `let` enforces that without us tracking a flag.
    private static let sslInit: Void = {
        RTCInitializeSSL()
    }()

    init(api: CueAPI, state: AppState) {
        _ = Self.sslInit
        self.api = api
        self.state = state
        let enc = RTCDefaultVideoEncoderFactory()
        let dec = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: enc, decoderFactory: dec)
        super.init()
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Public

    func start(context: Context) async {
        guard phase == .idle || phase == .ended || phase == .error else { return }
        phase = .connecting
        errorMessage = nil
        userTranscript = ""
        assistantTranscript = ""

        log.info("start session episode=\(context.episodeTitle, privacy: .public) pausedAt=\(context.pausedAtSeconds)")

        do {
            let resp = try await api.requestVoiceSession(
                audioUrl: context.audioUrl,
                pausedAtSeconds: context.pausedAtSeconds,
                totalDurationSeconds: context.totalDurationSeconds,
                episodeTitle: context.episodeTitle,
                showTitle: context.showTitle
            )
            log.info("mint ok value_prefix=\(resp.value.prefix(10), privacy: .public) ctxChars=\(resp.contextMessage?.count ?? 0)")
            self.pendingContextMessage = resp.contextMessage

            try setupPeerConnection()
            configureAudioSessionForWebRTC()
            registerInterruptionObserver()
            try await performSDPExchange(ephemeralToken: resp.value)

            // From here, RTCDataChannelDelegate.dataChannelDidChangeState
            // will flip to .listening once the channel opens and we've
            // sent the context message.
        } catch {
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            phase = .error
            teardown()
        }
    }

    func stop() {
        log.info("stop session")
        phase = .ended
        teardown()
    }

    // MARK: - Setup

    private func setupPeerConnection() throws {
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw NSError(domain: "RealtimeVoice", code: 100,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create RTCPeerConnection"])
        }
        self.peerConnection = pc

        // Mic track — unified-plan default direction is sendrecv, so
        // OpenAI's audio comes back on the same transceiver.
        let audioSource = factory.audioSource(with: nil)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "cue-mic-0")
        pc.add(audioTrack, streamIds: ["cue-mic-stream"])

        // Data channel — OpenAI insists on the label "oai-events".
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let dc = pc.dataChannel(forLabel: "oai-events", configuration: dcConfig) else {
            throw NSError(domain: "RealtimeVoice", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create RTCDataChannel"])
        }
        dc.delegate = self
        self.dataChannel = dc
    }

    private func configureAudioSessionForWebRTC() {
        // Tell WebRTC what category/mode/options to use whenever IT
        // (re)activates the audio session, otherwise our local override
        // gets reset the moment audio starts flowing.
        //
        // .videoChat routes to the loud speaker by default; .voiceChat
        // assumes phone-to-ear use and pins output to the earpiece even
        // when .defaultToSpeaker is set and overrideOutputAudioPort is
        // called — which is the bug we kept hitting.
        let webRTCConfig = RTCAudioSessionConfiguration.webRTC()
        webRTCConfig.category = AVAudioSession.Category.playAndRecord.rawValue
        webRTCConfig.categoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        webRTCConfig.mode = AVAudioSession.Mode.videoChat.rawValue
        RTCAudioSessionConfiguration.setWebRTC(webRTCConfig)

        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setConfiguration(webRTCConfig, active: true)
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            log.error("RTCAudioSession config failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-assert the loud-speaker route. Safe to call any time after the
    /// session is active; useful after WebRTC has fully wired up audio
    /// since its activation can clobber the initial override.
    private func forceSpeakerOutput() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            log.error("overrideOutputAudioPort failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func registerInterruptionObserver() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let userInfo = note.userInfo,
                  let raw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .began
            else { return }
            log.notice("audio session interruption — stopping voice session")
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    // MARK: - SDP exchange

    private func performSDPExchange(ephemeralToken: String) async throws {
        guard let pc = peerConnection else {
            throw NSError(domain: "RealtimeVoice", code: 200,
                          userInfo: [NSLocalizedDescriptionKey: "No peer connection"])
        }

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        let offer = try await pc.offer(for: offerConstraints)
        try await pc.setLocalDescription(offer)

        let url = URL(string: "https://api.openai.com/v1/realtime/calls?model=gpt-realtime-2")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(ephemeralToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        req.httpBody = offer.sdp.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "RealtimeVoice", code: 201,
                          userInfo: [NSLocalizedDescriptionKey: "Non-HTTP SDP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw NSError(domain: "RealtimeVoice", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "OpenAI SDP exchange failed (\(http.statusCode)): \(body.prefix(500))"])
        }
        guard let answerSdp = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "RealtimeVoice", code: 202,
                          userInfo: [NSLocalizedDescriptionKey: "Bad SDP answer encoding"])
        }
        let answer = RTCSessionDescription(type: .answer, sdp: answerSdp)
        try await pc.setRemoteDescription(answer)
        log.info("SDP exchange complete, awaiting data channel open")
    }

    // MARK: - Data channel: open + inbound events

    private func handleDataChannelOpen() {
        // WebRTC has now fully wired up audio — re-assert speaker so its
        // activation doesn't leave us on the earpiece.
        forceSpeakerOutput()

        if let msg = pendingContextMessage {
            log.info("sending context message (\(msg.count) chars)")
            sendEvent([
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": msg]],
                ],
            ])
        }
        pendingContextMessage = nil
        phase = .listening
    }

    private func handleDataChannelMessage(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else {
            log.warning("unparseable data channel msg")
            return
        }

        log.debug("event: \(type, privacy: .public)")

        switch type {
        case "input_audio_buffer.speech_started":
            phase = .listening
        case "input_audio_buffer.speech_stopped":
            phase = .thinking
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                userTranscript = transcript
            }
        case "response.created":
            phase = .thinking
            assistantTranscript = ""
        // gpt-realtime-2 (GA) emits the `output_audio_transcript.*` variants;
        // the older beta emitted `audio_transcript.*`. Handle both so the
        // assistant transcript renders regardless of model version.
        case "response.audio_transcript.delta",
             "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String {
                assistantTranscript += delta
                phase = .speaking
            }
        case "response.audio_transcript.done",
             "response.output_audio_transcript.done":
            if let transcript = json["transcript"] as? String {
                assistantTranscript = transcript
            }
        // Fallbacks for text-modality responses (no audio).
        case "response.text.delta",
             "response.output_text.delta":
            if let delta = json["delta"] as? String {
                assistantTranscript += delta
                phase = .speaking
            }
        case "response.text.done",
             "response.output_text.done":
            if let text = (json["text"] as? String) ?? (json["output_text"] as? String) {
                assistantTranscript = text
            }
        case "response.output_item.done":
            if let item = json["item"] as? [String: Any],
               let itemType = item["type"] as? String, itemType == "function_call",
               let name = item["name"] as? String,
               let callId = item["call_id"] as? String {
                let argsStr = (item["arguments"] as? String) ?? "{}"
                let argsData = argsStr.data(using: .utf8) ?? Data()
                let args = ((try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any]) ?? [:]
                Task { await self.dispatchFunctionCall(name: name, callId: callId, args: args) }
            }
        case "response.done":
            // Model finished current response — leave phase where it is.
            break
        case "error":
            let err = json["error"] as? [String: Any]
            let msg = (err?["message"] as? String) ?? "unknown realtime error"
            log.error("realtime error: \(msg, privacy: .public)")
            errorMessage = msg
            phase = .error
        default:
            // Many event types we don't need (deltas of input audio
            // transcription, response.content_part.*, etc.).
            break
        }
    }

    // MARK: - Tool dispatch

    private func dispatchFunctionCall(name: String, callId: String, args: [String: Any]) async {
        guard let state = state else { return }
        let result = await RealtimeTools.dispatch(name: name, args: args, state: state, api: api)

        let outputJSON: String
        switch result {
        case .terminal(let json), .nonTerminal(let json):
            outputJSON = json
        }

        sendEvent([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": outputJSON,
            ],
        ])

        switch result {
        case .terminal:
            // Grace so OpenAI registers the output before we close the
            // data channel; otherwise the model logs a "function_call
            // never completed" warning.
            try? await Task.sleep(nanoseconds: 100_000_000)
            state.resumeAfterVoice()
        case .nonTerminal:
            // Nudge the model to speak its follow-up.
            sendEvent(["type": "response.create"])
        }
    }

    // MARK: - Send helper

    private func sendEvent(_ obj: [String: Any]) {
        guard let dc = dataChannel else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else {
            log.error("sendEvent: failed to encode \(obj.keys.joined(separator: ","), privacy: .public)")
            return
        }
        let buf = RTCDataBuffer(data: data, isBinary: false)
        dc.sendData(buf)
    }

    // MARK: - Teardown

    private func teardown() {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        pendingContextMessage = nil

        // Restore AudioPlayer's preferred config so the podcast can
        // resume cleanly through the speaker without WebRTC's voiceChat
        // mode lingering.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
        )
        try? session.setActive(true)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension RealtimeVoiceSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log.info("ICE state: \(newState.rawValue)")
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - RTCDataChannelDelegate

extension RealtimeVoiceSession: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        log.info("data channel readyState=\(state.rawValue)")
        if state == .open {
            Task { @MainActor [weak self] in
                self?.handleDataChannelOpen()
            }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        Task { @MainActor [weak self] in
            self?.handleDataChannelMessage(data)
        }
    }
}
