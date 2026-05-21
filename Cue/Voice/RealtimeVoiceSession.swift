import Foundation
import AVFoundation
import Combine
import Observation
import WebRTC
import os

private let log = Logger(subsystem: "com.toug.cue", category: "RealtimeVoice")
private let startupMaxAttempts = 3
private let startupRetryBaseDelayNs: UInt64 = 350_000_000

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
        let preparedSession: VoiceSessionResponse?
        let preparedSessionRequest: VoiceSessionPrefetchRequest?
        let preparedSessionFetchMs: Int?
    }

    private enum StartupStage: String {
        case sessionMint = "session mint"
        case peerConnection = "peer connection setup"
        case sdpExchange = "SDP exchange"
    }

    private struct StartupFailure: LocalizedError {
        let stage: StartupStage
        let underlying: Error

        var errorDescription: String? { underlying.localizedDescription }
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

    /// Forwards every realtime event to cue-server for Langfuse tracing.
    /// Non-nil only when the server returned a traceId on session mint.
    @ObservationIgnored private var telemetry: VoiceTelemetry?
    @ObservationIgnored private(set) var traceId: String?
    @ObservationIgnored private var startupMetrics: StartupMetrics?

    private struct StartupMetrics {
        let startedAt: Date
        var sessionSource: String = "mint"
        var sessionMs: Int = 0
        var preparedSessionFetchMs: Int?
        var peerSetupMs: Int?
        var sdpExchangeMs: Int?
        var attempt: Int = 1
    }

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
        levelTimer?.cancel()
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
    /// instead of strobing on every 20 Hz tick. `outputLevel` is smoothed
    /// more aggressively (lower alpha) — the waveform reads better with a
    /// more lyrical level signal vs the orb's tighter mic tracking. Skips
    /// the assignment when the smoothed delta is below the visible
    /// threshold — @Observable mutations fire `withMutation` regardless of
    /// whether the value actually changed, so deduping here avoids
    /// invalidating any view that reads `inputLevel` / `outputLevel` (the
    /// orb + waveform) 20 times per second of silence.
    private func applyLevels(input: Float, output: Float) {
        let inputAlpha: Float = 0.4
        let outputAlpha: Float = 0.26
        let nextIn  = inputLevel  + (input  - inputLevel)  * inputAlpha
        let nextOut = outputLevel + (output - outputLevel) * outputAlpha
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
        startupMetrics = StartupMetrics(
            startedAt: Date(),
            preparedSessionFetchMs: context.preparedSessionFetchMs
        )
        startLevelMetering()

        log.info("start session episode=\(context.episodeTitle, privacy: .public) pausedAt=\(context.pausedAtSeconds) maxAttempts=\(startupMaxAttempts)")

        for attempt in 1...startupMaxAttempts {
            let attemptStarted = Date()
            log.info("start attempt \(attempt)/\(startupMaxAttempts) begin")
            do {
                try await runStartupAttempt(context: context, attempt: attempt)
                log.info("start attempt \(attempt)/\(startupMaxAttempts) succeeded in \(Self.elapsedMs(since: attemptStarted))ms")
                return
            } catch {
                cleanupFailedStartupAttempt(error)

                guard phase == .connecting else { return }
                let canRetry = attempt < startupMaxAttempts && isRetryableStartupError(error)
                let stage = startupStage(from: error)?.rawValue ?? "startup"
                let details = startupFailureDetails(error)
                log.warning("start attempt \(attempt)/\(startupMaxAttempts) failed after \(Self.elapsedMs(since: attemptStarted))ms stage=\(stage, privacy: .public) retryable=\(canRetry) details=\(details, privacy: .public)")

                if canRetry {
                    let delay = startupRetryDelayNs(attempt: attempt)
                    log.info("start attempt \(attempt)/\(startupMaxAttempts) scheduling retry in \(String(format: "%.2f", Double(delay) / 1_000_000_000.0))s")
                    startLevelMetering()
                    try? await Task.sleep(nanoseconds: delay)
                    guard phase == .connecting else { return }
                    continue
                }

                log.error("start failed permanently after \(attempt) attempt(s) stage=\(stage, privacy: .public) details=\(details, privacy: .public)")
                errorMessage = error.localizedDescription
                phase = .error
                teardown()
                return
            }
        }
    }

    func stop() {
        log.info("stop session")
        phase = .ended
        startupMetrics = nil
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

    private func runStartupAttempt(context: Context, attempt: Int) async throws {
        let resp: VoiceSessionResponse
        var sessionSource = "mint"
        var sessionMs = 0
        var activatedTraceId: String?
        if attempt == 1, let prepared = context.preparedSession {
            resp = prepared
            sessionSource = "prefetch"
            log.info("start attempt \(attempt)/\(startupMaxAttempts) using prefetched voice session expiresAt=\(prepared.expiresAt ?? 0) ctxChars=\(prepared.contextMessage?.count ?? 0) traceId=\(prepared.traceId ?? "<none>", privacy: .public)")
            if prepared.traceId == nil {
                let activationStarted = Date()
                let request = context.preparedSessionRequest
                do {
                    let activated = try await api.activatePrefetchedVoiceSession(
                        audioUrl: request?.audioUrl ?? context.audioUrl,
                        pausedAtSeconds: request?.pausedAtSeconds ?? context.pausedAtSeconds,
                        totalDurationSeconds: request?.totalDurationSeconds ?? context.totalDurationSeconds,
                        episodeTitle: request?.episodeTitle ?? context.episodeTitle,
                        showTitle: request?.showTitle ?? context.showTitle,
                        prefetchFetchMs: context.preparedSessionFetchMs,
                        tokenExpiresAt: prepared.expiresAt
                    )
                    activatedTraceId = activated.traceId
                    log.info("start attempt \(attempt)/\(startupMaxAttempts) activated prefetched trace in \(Self.elapsedMs(since: activationStarted))ms traceId=\(activated.traceId ?? "<none>", privacy: .public)")
                } catch {
                    // Tracing should never block the voice UX. If activation
                    // fails, continue without Langfuse telemetry for this
                    // prefetched session.
                    log.warning("start attempt \(attempt)/\(startupMaxAttempts) prefetched trace activation failed in \(Self.elapsedMs(since: activationStarted))ms details=\(self.startupFailureDetails(error), privacy: .public)")
                }
            }
        } else {
            let mintStarted = Date()
            log.info("start attempt \(attempt)/\(startupMaxAttempts) mint begin")
            do {
                resp = try await api.requestVoiceSession(
                    audioUrl: context.audioUrl,
                    pausedAtSeconds: context.pausedAtSeconds,
                    totalDurationSeconds: context.totalDurationSeconds,
                    episodeTitle: context.episodeTitle,
                    showTitle: context.showTitle
                )
            } catch {
                log.warning("start attempt \(attempt)/\(startupMaxAttempts) mint failed in \(Self.elapsedMs(since: mintStarted))ms details=\(self.startupFailureDetails(error), privacy: .public)")
                throw StartupFailure(stage: .sessionMint, underlying: error)
            }
            sessionMs = Self.elapsedMs(since: mintStarted)
        }

        startupMetrics?.attempt = attempt
        startupMetrics?.sessionSource = sessionSource
        startupMetrics?.sessionMs = sessionMs
        let traceIdForTelemetry = resp.traceId ?? activatedTraceId
        log.info("start attempt \(attempt)/\(startupMaxAttempts) \(sessionSource, privacy: .public) ok in \(sessionMs)ms expiresAt=\(resp.expiresAt ?? 0) ctxChars=\(resp.contextMessage?.count ?? 0) traceId=\(traceIdForTelemetry ?? "<none>", privacy: .public)")
        self.pendingContextMessage = resp.contextMessage
        if let tid = traceIdForTelemetry {
            self.traceId = tid
            let tel = VoiceTelemetry(traceId: tid, api: api)
            self.telemetry = tel
            Task { await tel.start() }
        }

        let peerStarted = Date()
        log.info("start attempt \(attempt)/\(startupMaxAttempts) peer setup begin traceId=\(self.traceId ?? "<none>", privacy: .public)")
        do {
            try setupPeerConnection()
        } catch {
            log.warning("start attempt \(attempt)/\(startupMaxAttempts) peer setup failed in \(Self.elapsedMs(since: peerStarted))ms details=\(self.startupFailureDetails(error), privacy: .public)")
            throw StartupFailure(stage: .peerConnection, underlying: error)
        }
        let peerMs = Self.elapsedMs(since: peerStarted)
        startupMetrics?.peerSetupMs = peerMs
        log.info("start attempt \(attempt)/\(startupMaxAttempts) peer setup ok in \(peerMs)ms")

        // POC: skip `configureAudioSessionForWebRTC` — the custom
        // RTCAudioDevice replaces WebRTC's default ADM entirely, so
        // WebRTC isn't operating its own audio unit and has no reason
        // to touch the session config. MicCapture owns category/mode/
        // VPIO; WebRTC reads/writes PCM via our ADM only.
        registerInterruptionObserver()

        let sdpStarted = Date()
        log.info("start attempt \(attempt)/\(startupMaxAttempts) SDP exchange begin traceId=\(self.traceId ?? "<none>", privacy: .public)")
        do {
            try await performSDPExchange(ephemeralToken: resp.value)
        } catch {
            log.warning("start attempt \(attempt)/\(startupMaxAttempts) SDP exchange failed in \(Self.elapsedMs(since: sdpStarted))ms details=\(self.startupFailureDetails(error), privacy: .public)")
            throw StartupFailure(stage: .sdpExchange, underlying: error)
        }
        let sdpMs = Self.elapsedMs(since: sdpStarted)
        startupMetrics?.sdpExchangeMs = sdpMs
        log.info("start attempt \(attempt)/\(startupMaxAttempts) SDP exchange ok in \(sdpMs)ms traceId=\(self.traceId ?? "<none>", privacy: .public)")

        // From here, RTCDataChannelDelegate.dataChannelDidChangeState
        // will flip to .listening once the channel opens and we've
        // sent the context message.
    }

    private func cleanupFailedStartupAttempt(_ error: Error) {
        if let tel = telemetry {
            let tid = traceId ?? "<none>"
            log.info("cleanup failed startup attempt traceId=\(tid, privacy: .public) stage=\(self.startupStage(from: error)?.rawValue ?? "startup", privacy: .public)")
            tel.record(
                direction: .outbound,
                type: "session.start_failed",
                payload: [
                    "stage": startupStage(from: error)?.rawValue ?? "startup",
                    "error": error.localizedDescription,
                ]
            )
            Task.detached { await tel.stop() }
            telemetry = nil
            traceId = nil
        }
        teardown()
    }

    private func startupStage(from error: Error) -> StartupStage? {
        (error as? StartupFailure)?.stage
    }

    private func startupRetryDelayNs(attempt: Int) -> UInt64 {
        startupRetryBaseDelayNs * UInt64(attempt)
    }

    private static func elapsedMs(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }

    private func startupFailureDetails(_ error: Error) -> String {
        let underlying = (error as? StartupFailure)?.underlying ?? error
        if let apiError = underlying as? CueAPIError {
            switch apiError {
            case .server(let status, let message):
                return "CueAPIError.server status=\(status) message=\(message)"
            default:
                return "CueAPIError.\(String(describing: apiError))"
            }
        }

        let nsError = underlying as NSError
        return "domain=\(nsError.domain) code=\(nsError.code) description=\(underlying.localizedDescription)"
    }

    private func isRetryableStartupError(_ error: Error) -> Bool {
        guard startupStage(from: error) != .peerConnection else { return false }
        let underlying = (error as? StartupFailure)?.underlying ?? error

        if let apiError = underlying as? CueAPIError,
           case .server(let status, _) = apiError {
            return status == 429 || status == 500 || status == 502 || status == 503 || status == 504
        }

        let nsError = underlying as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch URLError.Code(rawValue: nsError.code) {
        case .networkConnectionLost,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

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
        let offerStarted = Date()
        log.info("SDP create offer begin")
        let offer = try await pc.offer(for: offerConstraints)
        log.info("SDP create offer ok in \(Self.elapsedMs(since: offerStarted))ms sdpChars=\(offer.sdp.count)")
        let localStarted = Date()
        log.info("SDP set local description begin")
        try await pc.setLocalDescription(offer)
        log.info("SDP set local description ok in \(Self.elapsedMs(since: localStarted))ms")

        let url = URL(string: "https://api.openai.com/v1/realtime/calls?model=gpt-realtime-2")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(ephemeralToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        req.httpBody = offer.sdp.data(using: .utf8)

        let postStarted = Date()
        log.info("SDP POST begin url=\(url.absoluteString, privacy: .public) offerBytes=\(req.httpBody?.count ?? 0)")
        let (data, response) = try await URLSession.shared.data(for: req)
        log.info("SDP POST transport ok in \(Self.elapsedMs(since: postStarted))ms bytes=\(data.count)")
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "RealtimeVoice", code: 201,
                          userInfo: [NSLocalizedDescriptionKey: "Non-HTTP SDP response"])
        }
        log.info("SDP POST status=\(http.statusCode) bytes=\(data.count)")
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            log.error("SDP POST failed status=\(http.statusCode) bodyPrefix=\(body.prefix(500), privacy: .public)")
            throw NSError(domain: "RealtimeVoice", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "OpenAI SDP exchange failed (\(http.statusCode)): \(body.prefix(500))"])
        }
        guard let answerSdp = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "RealtimeVoice", code: 202,
                          userInfo: [NSLocalizedDescriptionKey: "Bad SDP answer encoding"])
        }
        let answer = RTCSessionDescription(type: .answer, sdp: answerSdp)
        let remoteStarted = Date()
        log.info("SDP set remote description begin answerChars=\(answerSdp.count)")
        try await pc.setRemoteDescription(answer)
        log.info("SDP set remote description ok in \(Self.elapsedMs(since: remoteStarted))ms")
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
        recordReadyLatency()
        SoundEffectPlayer.shared.play(.voiceReady)
    }

    private func recordReadyLatency() {
        guard let metrics = startupMetrics else { return }
        startupMetrics = nil
        let totalMs = Self.elapsedMs(since: metrics.startedAt)
        let savedMs = metrics.sessionSource == "prefetch"
            ? metrics.preparedSessionFetchMs
            : nil
        let estimatedWithoutPrefetchMs = savedMs.map { totalMs + $0 }
        log.info("voice ready total=\(totalMs)ms source=\(metrics.sessionSource, privacy: .public) session=\(metrics.sessionMs)ms saved=\(savedMs ?? 0)ms peer=\(metrics.peerSetupMs ?? -1)ms sdp=\(metrics.sdpExchangeMs ?? -1)ms traceId=\(self.traceId ?? "<none>", privacy: .public)")
        Analytics.shared.track(
            "voice_session_ready",
            properties: [
                "trace_id": traceId,
                "startup_source": metrics.sessionSource,
                "attempt": metrics.attempt,
                "total_ms": totalMs,
                "session_ms": metrics.sessionMs,
                "prefetch_saved_ms": savedMs,
                "estimated_without_prefetch_ms": estimatedWithoutPrefetchMs,
                "peer_setup_ms": metrics.peerSetupMs,
                "sdp_exchange_ms": metrics.sdpExchangeMs,
            ]
        )
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
                let wasFirst = (userTranscript ?? "").isEmpty
                userTranscript = transcript
                // PostHog: a non-empty user transcript is the canonical
                // "user actually spoke" signal. We bump the count on every
                // completed transcript so closeVoiceAgent has an accurate
                // utterance_count; we fire the named event only on the
                // first one of the session.
                state?.recordVoiceUtterance(isFirst: wasFirst)
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
