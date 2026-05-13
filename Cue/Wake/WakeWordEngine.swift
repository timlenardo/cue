#if os(iOS)
import AVFoundation
import Foundation
import OSLog
import WhisperKit

/// On-device wake-word detector backed by WhisperKit (rolling-window
/// Whisper inference + regex match). `AppState` consumes the engine
/// through `start() / stop() / onDetect` and doesn't care what's
/// underneath.
///
/// **How it works**
/// - Subscribes to `MicCapture.shared` for raw input buffers.
/// - Resamples each buffer to 16 kHz mono float and appends to a rolling
///   ~2s ring (only the most recent samples are kept).
/// - Every ~600 ms, the rolling window is handed to a Whisper tiny.en
///   transcription. Each transcript is logged ("whisper: …") regardless
///   of trigger match, so you can see exactly what the mic is hearing.
/// - If the transcript matches any trigger regex (case-insensitive,
///   word-boundary), `onDetect` fires on the main actor.
///
/// **Model**
/// - "openai_whisper-tiny.en" — ~39 M params, ~75 MB on disk. Auto-
///   downloaded from HuggingFace on first launch and cached locally.
final class WakeWordEngine: @unchecked Sendable {

    /// Fires whenever the wake phrase is recognised (already on @MainActor).
    /// Debounced by `Debounce` seconds.
    var onDetect: (@MainActor () -> Void)?

    enum State { case idle, loading, listening, denied, failed(String) }
    private(set) var state: State = .idle

    // MARK: - Tunables
    private static let TargetSampleRate: Double = 16_000
    private static let WindowSeconds: Double = 2.0
    private static let WindowSamples: Int = Int(16_000 * 2)
    /// Minimum gap between Whisper inferences. Smaller = more responsive
    /// but more CPU; ~600 ms is comfortable on iPhone Neural Engine.
    private static let InferenceIntervalMs: Int = 600
    private static let Debounce: TimeInterval = 1.5
    /// English-only tiny model. Smallest viable Whisper for wake-word.
    private static let ModelName = "openai_whisper-tiny.en"

    /// Triggers we accept. Word-boundary, case-insensitive. Add more
    /// aliases here as you hear false-negatives in the logs.
    private static let TriggerPattern = #"\b(alexa|qq|q\s*q|cue\s*cue|queue\s*queue|kew\s*kew|coo\s*coo|hey\s+cue|hey\s+q(ueue|ew|u)?)\b"#

    // MARK: - State
    private let triggerRegex: NSRegularExpression = {
        // The pattern is a literal — force-try is fine.
        try! NSRegularExpression(pattern: WakeWordEngine.TriggerPattern, options: [.caseInsensitive])
    }()
    private var pipeline: WhisperKit?
    private var lastFireAt: Date = .distantPast
    private let stateLock = NSLock()
    private var lastInferenceAt: Date = .distantPast
    private var inferenceInFlight: Bool = false

    // Rolling 16 kHz mono buffer.
    private let bufLock = NSLock()
    private var rolling: [Float] = []

    // Mic subscription / resampler.
    private var bufferToken: UUID?
    private let convertLock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?

    private let log = Logger(subsystem: "app.cue", category: "wake")

    // MARK: - Public lifecycle

    @MainActor
    func start() {
        guard bufferToken == nil else { return }
        loadPipelineIfNeeded()
        bufferToken = MicCapture.shared.addBufferHandler { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        state = .listening
        log.info("whisper wake handler registered")
    }

    @MainActor
    func stop() {
        if let token = bufferToken {
            MicCapture.shared.removeBufferHandler(token)
            bufferToken = nil
        }
        bufLock.lock()
        rolling.removeAll(keepingCapacity: true)
        bufLock.unlock()
        stateLock.lock()
        lastInferenceAt = .distantPast
        stateLock.unlock()
        if case .listening = state { state = .idle }
        log.info("whisper wake handler unregistered")
    }

    // MARK: - Pipeline boot

    @MainActor
    private func loadPipelineIfNeeded() {
        guard pipeline == nil else { return }
        if case .loading = state { return }
        state = .loading
        log.info("whisper loading model: \(Self.ModelName, privacy: .public)")
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let config = WhisperKitConfig(model: Self.ModelName)
                let pipe = try await WhisperKit(config)
                await MainActor.run {
                    guard let self else { return }
                    self.pipeline = pipe
                    if self.bufferToken != nil {
                        self.state = .listening
                    } else {
                        self.state = .idle
                    }
                    self.log.info("whisper model ready")
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    self?.state = .failed(msg)
                    self?.log.error("whisper model load failed: \(msg, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Audio path (audio render thread)

    private func handle(buffer: AVAudioPCMBuffer) {
        let samples = resample(buffer: buffer)
        guard !samples.isEmpty else { return }

        bufLock.lock()
        rolling.append(contentsOf: samples)
        if rolling.count > Self.WindowSamples {
            rolling.removeFirst(rolling.count - Self.WindowSamples)
        }
        // Snapshot under the lock; release immediately so we don't block
        // the audio thread while inference runs.
        let snapshot = rolling
        bufLock.unlock()

        // Only run inference once we've accumulated at least ~700 ms of
        // audio — anything shorter is too noisy for Whisper.
        guard snapshot.count >= Int(Self.TargetSampleRate * 0.7) else { return }

        // Throttle inference cadence + single-in-flight gate.
        let now = Date()
        stateLock.lock()
        let dueMs = now.timeIntervalSince(lastInferenceAt) * 1000
        if dueMs < Double(Self.InferenceIntervalMs) || inferenceInFlight {
            stateLock.unlock()
            return
        }
        guard let pipe = pipeline else {
            stateLock.unlock()
            return
        }
        lastInferenceAt = now
        inferenceInFlight = true
        stateLock.unlock()

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runInference(pipe: pipe, samples: snapshot)
            self?.stateLock.lock()
            self?.inferenceInFlight = false
            self?.stateLock.unlock()
        }
    }

    private func runInference(pipe: WhisperKit, samples: [Float]) async {
        do {
            let opts = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: "en",
                temperature: 0,
                sampleLength: 224,
                usePrefillPrompt: false,
                skipSpecialTokens: true,
                withoutTimestamps: true
            )
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: opts)
            let text = results
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { self.handleTranscript(text) }
        } catch {
            let msg = error.localizedDescription
            log.error("whisper transcribe failed: \(msg, privacy: .public)")
        }
    }

    @MainActor
    private func handleTranscript(_ text: String) {
        // Always log the decoded text so dev can see what the mic
        // is picking up. Whisper emits "(silence)" / "[BLANK_AUDIO]" /
        // empty when nothing speech-like was heard — leave those alone.
        if text.isEmpty {
            log.info("whisper: (empty)")
        } else {
            // Disabled: with the always-on background mic, logging the
            // decoded transcript as public OSLog is a privacy leak —
            // anything spoken near the phone shows up in Console /
            // sysdiagnose. Re-enable with `.private` if needed for debug.
            // log.info("whisper: '\(text, privacy: .public)'")
        }

        let range = NSRange(text.startIndex..., in: text)
        guard triggerRegex.firstMatch(in: text, options: [], range: range) != nil else { return }

        let now = Date()
        if now.timeIntervalSince(lastFireAt) < Self.Debounce {
            log.info("whisper hit (debounced): '\(text, privacy: .public)'")
            return
        }
        lastFireAt = now
        log.info("whisper hit: '\(text, privacy: .public)'")
        onDetect?()
    }

    // MARK: - Resampler (audio render thread)

    private func resample(buffer: AVAudioPCMBuffer) -> [Float] {
        let bufFormat = buffer.format
        convertLock.lock()
        if sourceFormat?.sampleRate != bufFormat.sampleRate
            || sourceFormat?.channelCount != bufFormat.channelCount {
            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.TargetSampleRate,
                channels: 1,
                interleaved: false
            ) else {
                convertLock.unlock()
                return []
            }
            sourceFormat = bufFormat
            targetFormat = target
            converter = AVAudioConverter(from: bufFormat, to: target)
            log.info("whisper converter ready: \(bufFormat.sampleRate, format: .fixed(precision: 0))Hz x \(bufFormat.channelCount)ch -> 16kHz mono")
        }
        guard let converter, let target = targetFormat else {
            convertLock.unlock()
            return []
        }
        convertLock.unlock()

        let outCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * target.sampleRate / bufFormat.sampleRate + 64
        )
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return [] }
        var error: NSError?
        var fed = false
        let status = converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard status != .error, let channelData = out.floatChannelData?[0] else {
            if let error { log.error("convert: \(error.localizedDescription, privacy: .public)") }
            return []
        }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(out.frameLength)))
    }
}
#endif
