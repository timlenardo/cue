import Foundation
import AVFoundation
import Combine
import Observation
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
///      `AppState.closeVoiceAgent()` restart the podcast + wake engine.
///   6. `stop()` (or an `AVAudioSession.interruptionNotification`) closes
///      the peer connection cleanly and restores the podcast's audio
///      session config.
///
/// Mirrors voice-ai-playground/lib/providers/openai-realtime/client.ts
/// but translated to stasel/WebRTC's Swift API.
@MainActor
@Observable
final class RealtimeVoiceSession: NSObject {
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

    private(set) var phase: Phase = .idle
    private(set) var userTranscript: String = ""
    private(set) var assistantTranscript: String = ""
    private(set) var errorMessage: String?

    /// Smoothed 0..1 amplitude of the user's mic, sourced from the WebRTC
    /// `media-source` audio-level stat (pre-encoding). Drives the play-button
    /// orb bounce in voice mode.
    private(set) var inputLevel: Float = 0
    /// Smoothed 0..1 amplitude of the assistant's TTS, sourced from the
    /// WebRTC `inbound-rtp` audio-level stat. Stays at 0 whenever the
    /// receiver isn't actually delivering audio frames, which lets the
    /// oscilloscope go flat between turns.
    private(set) var outputLevel: Float = 0

    @ObservationIgnored private var levelTimer: AnyCancellable?

    @ObservationIgnored private let api: CueAPI
    @ObservationIgnored private weak var state: AppState?

    @ObservationIgnored private let factory: RTCPeerConnectionFactory
    @ObservationIgnored private var peerConnection: RTCPeerConnection?
    @ObservationIgnored private var dataChannel: RTCDataChannel?
    @ObservationIgnored private var pendingContextMessage: String?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    /// Forwards every realtime event to cue-server for LangSmith tracing.
    /// Non-nil only when the server returned a traceId on session mint.
    @ObservationIgnored private var telemetry: VoiceTelemetry?
    @ObservationIgnored private(set) var traceId: String?

    /// RTCInitializeSSL must be called exactly once per process. This
    /// static `let` enforces that without us tracking a flag.
    private static let sslInit: Void = {
        RTCInitializeSSL()
    }()

    /// Custom WebRTC audio device — pulls mic samples from MicCapture's
    /// AVAudioEngine and plays inbound audio back through the same engine.
    /// POC for the unified pipeline; supersedes WebRTC's default ADM so
    /// there's one input HAL owner across all audio surfaces.
    @ObservationIgnored private let audioDevice: CueAudioDevice

    init(api: CueAPI, state: AppState) {
        _ = Self.sslInit
        self.api = api
        self.state = state
        let enc = RTCDefaultVideoEncoderFactory()
        let dec = RTCDefaultVideoDecoderFactory()
        let device = CueAudioDevice()
        self.audioDevice = device
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: enc,
            decoderFactory: dec,
            audioDevice: device
        )
        super.init()
        // NB: level metering is started from `start(context:)` once the
        // session is committed to running. Starting it in init() ran the
        // 20 Hz Combine pipeline through the entire construct → start gap
        // (and during the Connecting phase before `peerConnection` is set
        // up the closure is a pure no-op that still mutates @Observable
        // inputLevel/outputLevel to 0 every 50 ms).
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Polls `peerConnection.statistics` at ~20Hz and pulls audioLevel
    /// out of the `media-source` (mic) and `inbound-rtp` (assistant) stats.
    /// Empty / disconnected state decays both levels to 0.
    private func startLevelMetering() {
        levelTimer = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pollLevels() }
    }

    private func pollLevels() {
        guard let pc = peerConnection else {
            applyLevels(input: 0, output: 0)
            return
        }
        pc.statistics { [weak self] report in
            var input: Float = 0
            var output: Float = 0
            for (_, stat) in report.statistics {
                // Only consider audio stats; `kind` is the modern key, but
                // some builds emit `mediaType` instead.
                let kind = (stat.values["kind"] as? String)
                    ?? (stat.values["mediaType"] as? String)
                guard kind == "audio" else { continue }
                guard let level = (stat.values["audioLevel"] as? NSNumber)?.floatValue else { continue }
                switch stat.type {
                case "media-source":
                    input = max(input, level)
                case "inbound-rtp":
                    output = max(output, level)
                default:
                    break
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.applyLevels(input: input, output: output)
            }
        }
    }

    /// One-pole low-pass into the published levels so the UI breathes
    /// instead of strobing on every 20 Hz tick. Skips the assignment when
    /// the smoothed delta is below the visible threshold — @Observable
    /// mutations fire `withMutation` regardless of whether the value
    /// actually changed, so deduping here avoids invalidating any view
    /// that reads `inputLevel` / `outputLevel` (the orb + waveform) 20
    /// times per second of silence.
    private func applyLevels(input: Float, output: Float) {
        let alpha: Float = 0.4
        let nextIn  = inputLevel  + (input  - inputLevel)  * alpha
        let nextOut = outputLevel + (output - outputLevel) * alpha
        if abs(nextIn  - inputLevel)  > 0.001 { inputLevel  = nextIn  }
        if abs(nextOut - outputLevel) > 0.001 { outputLevel = nextOut }
    }

    // MARK: - Public

    func start(context: Context) async {
        guard phase == .idle || phase == .ended || phase == .error else { return }
        phase = .connecting
        errorMessage = nil
        userTranscript = ""
        assistantTranscript = ""
        startLevelMetering()

        log.info("start session episode=\(context.episodeTitle, privacy: .public) pausedAt=\(context.pausedAtSeconds)")

        do {
            let resp = try await api.requestVoiceSession(
                audioUrl: context.audioUrl,
                pausedAtSeconds: context.pausedAtSeconds,
                totalDurationSeconds: context.totalDurationSeconds,
                episodeTitle: context.episodeTitle,
                showTitle: context.showTitle
            )
            log.info("mint ok value_prefix=\(resp.value.prefix(10), privacy: .public) ctxChars=\(resp.contextMessage?.count ?? 0) traceId=\(resp.traceId ?? "<none>", privacy: .public)")
            self.pendingContextMessage = resp.contextMessage
            if let tid = resp.traceId {
                self.traceId = tid
                let tel = VoiceTelemetry(traceId: tid, api: api)
                self.telemetry = tel
                Task { await tel.start() }
            }

            try setupPeerConnection()
            // POC: skip `configureAudioSessionForWebRTC` — the custom
            // RTCAudioDevice replaces WebRTC's default ADM entirely, so
            // WebRTC isn't operating its own audio unit and has no reason
            // to touch the session config. MicCapture owns category/mode/
            // VPIO; WebRTC reads/writes PCM via our ADM only.
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
        if let tel = telemetry {
            telemetry = nil
            traceId = nil
            // Record the session-stop ping synchronously so it lands in the
            // buffer before the final flush; only the flush itself needs to
            // be detached so teardown doesn't block on it.
            tel.record(direction: .outbound, type: "session.stop", payload: ["reason": "client_stop"])
            Task.detached { await tel.stop() }
        }
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

        // Synchronous, ordered — see VoiceTelemetry.record's comment.
        telemetry?.record(direction: .inbound, type: type, payload: json)

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
        let result = await RealtimeTools.dispatch(
            name: name,
            args: args,
            state: state,
            api: api,
            traceId: traceId,
            callId: callId
        )

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
            state.closeVoiceAgent()
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

        let type = (obj["type"] as? String) ?? "unknown"
        telemetry?.record(direction: .outbound, type: type, payload: obj)
    }

    // MARK: - Teardown

    private func teardown() {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        levelTimer?.cancel()
        levelTimer = nil
        inputLevel = 0
        outputLevel = 0
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        pendingContextMessage = nil

        // POC: do NOT reconfigure the AVAudioSession here. With the custom
        // RTCAudioDevice (CueAudioDevice), MicCapture owns the session
        // category/mode/VPIO for the entire playback lifetime. Resetting
        // to `.spokenAudio` here would override MicCapture's `.voiceChat`
        // and leave the still-running VPIO engine under a stale config
        // until the next route change forces a bringUpEngine. WebRTC's
        // own audio unit is not active so it has nothing to clean up.
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
