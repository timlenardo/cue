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
final class WakeWordEngine: WakeEngine, @unchecked Sendable {

    /// Fires whenever the wake phrase is recognised (already on @MainActor).
    /// Debounced by `Debounce` seconds.
    var onDetect: (@MainActor () -> Void)?

    /// Fires for every non-empty Whisper transcript, regardless of trigger
    /// match. Used by the dev "wake word tracking" toggle to surface what
    /// the mic is hearing in real time. `isHit` is true iff the trigger
    /// regex matched (a real wake-word hit, not just background chatter).
    /// `levels` carries the peak amplitudes / clip rate observed in the
    /// audio that produced this transcript — surfaced behind the dev
    /// "audio levels" toggle. Nil iff no audio was observed since the
    /// previous inference (rare; basically only the first inference).
    var onTranscript: (@MainActor (_ text: String, _ isHit: Bool, _ levels: AudioLevelStats?) -> Void)?

    enum State { case idle, loading, listening, denied, failed(String) }
    private(set) var state: State = .idle

    // MARK: - Tunables
    private static let TargetSampleRate: Double = 16_000
    private static let WindowSeconds: Double = 2.0
    private static let WindowSamples: Int = Int(16_000 * 2)
    /// Minimum gap between Whisper inferences. Smaller = more responsive
    /// but more CPU. 250 ms gives us 4 overlapping windows per second —
    /// even a 200 ms blip lands inside at least one inference.
    private static let InferenceIntervalMs: Int = 250
    /// Minimum audio buffered before we'll run inference at all. 200 ms
    /// is roughly the floor before Whisper transcribes pure garbage.
    private static let MinAudioMs: Int = 200
    private static let Debounce: TimeInterval = 1.5
    /// English-only tiny model. Smallest viable Whisper for wake-word.
    private static let ModelName = "openai_whisper-tiny.en"

    // MARK: - Sensitivity (passed to Whisper's DecodingOptions)
    //
    // Whisper marks a segment as silent when `no-speech probability >
    // noSpeechThreshold` AND `avg log-prob < logProbThreshold`. Defaults
    // (0.6 / -1.0) are tuned for clean transcription; for wake-word we
    // want it MUCH more eager to emit text. Lowering both means we get
    // more false transcripts of background noise, but the trigger regex
    // already filters those — only specific words fire `onDetect`.

    /// Lower = more aggressive. Default 0.6. We set this very low (0.05)
    /// to establish the "Whisper hallucinates everything" floor —
    /// calibrate UP from here once the false-positive rate is measurable.
    private static let NoSpeechThreshold: Float = 0.05
    /// Lower (more negative) = more aggressive. Default -1.0. -3.0 means
    /// even low-confidence per-token decodings are accepted.
    private static let LogProbThreshold: Float = -3.0

    /// Software gain applied to resampled samples before they reach Whisper.
    /// VPIO's hardware AGC tends to leave samples peaking at ±0.1–0.2 even
    /// during normal speech, leaving most of the float range unused. Boosting
    /// by 2–3× (with clip to ±1.0) gives Whisper the full-range audio it
    /// was trained on. Higher values risk clipping artifacts at high volume.
    private static let SoftwareGain: Float = 3.0
    /// Silence padding (ms) prepended to each Whisper transcription. Short
    /// utterances near the leading edge of the buffer transcribe poorly
    /// because they're out-of-distribution — Whisper expects speech
    /// surrounded by audio context. 500 ms of leading silence gives the
    /// model breathing room and meaningfully improves quick-word recall.
    private static let LeadingSilencePadMs: Int = 500

    /// Triggers we accept. Word-boundary, case-insensitive. Add more
    /// aliases here as you hear false-negatives in the logs.
    private static let TriggerPattern = #"\b(orbit|orbits|orbital)\b"#

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

    // Rolling 16 kHz mono buffer. Fixed-capacity ring (sliding window)
    // so each push is bulk memcpy with no `removeFirst` memmove of the
    // remaining ~32 000 samples (was burning ~128 KB / mic tick on the
    // audio render thread).
    private let bufLock = NSLock()
    private var rolling = RingBuffer<Float>(capacity: WindowSamples, fill: 0)

    // Per-window audio level stats. Reset each time we dispatch an
    // inference. Tracked under `bufLock` because they're updated on the
    // audio render thread (same path as the ring push) and snapshotted
    // on the same thread when inference dispatches.
    //
    // We track pre-gain peak and post-gain pre-clip peak as the two
    // useful "in distribution?" signals. Post-clip would always cap at
    // 1.0 and hide the magnitude of overshoot.
    private var windowPreGainPeak: Float = 0
    private var windowPostGainPeak: Float = 0
    private var windowClippedCount: Int = 0
    private var windowSampleCount: Int = 0

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
        rolling.removeAll()
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
        let result = resample(buffer: buffer)
        guard !result.samples.isEmpty else { return }

        bufLock.lock()
        result.samples.withUnsafeBufferPointer { rolling.pushBack($0) }
        // Accumulate per-window stats alongside the ring push so the
        // levels reflect the same audio Whisper will eventually see.
        // Peaks max(), clip counts and sample counts sum.
        if result.preGainPeak > windowPreGainPeak { windowPreGainPeak = result.preGainPeak }
        if result.postGainPeak > windowPostGainPeak { windowPostGainPeak = result.postGainPeak }
        windowClippedCount += result.clippedCount
        windowSampleCount += result.samples.count
        let availableCount = rolling.count
        bufLock.unlock()

        // Only run inference once we've accumulated the minimum window.
        // Lower than ~200 ms is too short for Whisper to reliably decode
        // anything; higher than ~300 ms misses quick single-word triggers.
        let minSamples = Int(Self.TargetSampleRate * Double(Self.MinAudioMs) / 1000.0)
        guard availableCount >= minSamples else { return }

        // Throttle inference cadence + single-in-flight gate. Snapshot the
        // window only after we've decided to dispatch — that's where the
        // O(N) copy actually has to happen (handing samples to the
        // detached Task). Previously we snapshotted on every mic tick and
        // discarded it via the throttle bail, which paid a 32 000-Float
        // CoW-fork cost ~12×/sec for no benefit.
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

        bufLock.lock()
        let snapshot = rolling.snapshot()
        // Snapshot+reset the level stats atomically with the audio
        // snapshot so the stats describe the audio actually handed to
        // Whisper, and the next inference window starts fresh.
        let levels: AudioLevelStats? = windowSampleCount > 0
            ? AudioLevelStats(
                preGainPeak: windowPreGainPeak,
                postGainPeak: windowPostGainPeak,
                clippedCount: windowClippedCount,
                sampleCount: windowSampleCount
            )
            : nil
        windowPreGainPeak = 0
        windowPostGainPeak = 0
        windowClippedCount = 0
        windowSampleCount = 0
        bufLock.unlock()

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runInference(pipe: pipe, samples: snapshot, levels: levels)
            self?.stateLock.lock()
            self?.inferenceInFlight = false
            self?.stateLock.unlock()
        }
    }

    private func runInference(pipe: WhisperKit, samples: [Float], levels: AudioLevelStats?) async {
        do {
            var opts = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: "en",
                temperature: 0,
                sampleLength: 224,
                usePrefillPrompt: false,
                skipSpecialTokens: true,
                withoutTimestamps: true
            )
            // Make Whisper less eager to call audio "silence". Default
            // thresholds suppress quick single-word utterances; the wake
            // word needs them MUCH lower. The trigger regex filters any
            // false transcripts that result.
            opts.noSpeechThreshold = Self.NoSpeechThreshold
            opts.logProbThreshold = Self.LogProbThreshold
            // Pad with leading silence so short utterances aren't right at
            // the buffer edge. Whisper transcribes speech much more
            // reliably when it has audio context around it — even if that
            // context is zeros. Counter-intuitive but reproducible.
            let padSamples = Int(Self.TargetSampleRate * Double(Self.LeadingSilencePadMs) / 1000.0)
            let padded = padSamples > 0
                ? Array(repeating: Float(0), count: padSamples) + samples
                : samples
            let results = try await pipe.transcribe(audioArray: padded, decodeOptions: opts)
            let text = results
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { self.handleTranscript(text, levels: levels) }
        } catch {
            let msg = error.localizedDescription
            log.error("whisper transcribe failed: \(msg, privacy: .public)")
        }
    }

    @MainActor
    private func handleTranscript(_ text: String, levels: AudioLevelStats?) {
        let range = NSRange(text.startIndex..., in: text)
        let isHit = triggerRegex.firstMatch(in: text, options: [], range: range) != nil

        if !text.isEmpty {
            onTranscript?(text, isHit, levels)
        }

        guard isHit else { return }

        let now = Date()
        if now.timeIntervalSince(lastFireAt) < Self.Debounce {
            log.info("whisper hit (debounced): '\(text, privacy: .public)'")
            return
        }
        lastFireAt = now
        log.info("whisper hit: '\(text, privacy: .public)'")
        // PostHog event fires from the AppState wake.onDetect closure
        // instead of here — AppState is @MainActor and has UIApplication
        // access for the `in_app` property, which we need for the wake-
        // word false-positive-vs-real-use chart in Dashboard 4.
        onDetect?()
    }

    // MARK: - Resampler (audio render thread)

    /// Result of resampling one mic buffer. `samples` are the post-clip
    /// 16 kHz Float audio handed to the ring; the level fields describe
    /// what happened during the gain pass so the dev "audio levels"
    /// toggle can verify Whisper is being fed audio in its training
    /// distribution.
    private struct ResampleResult {
        let samples: [Float]
        let preGainPeak: Float    // max |raw|, before gain
        let postGainPeak: Float   // max |raw * gain|, before the ±1.0 clip
        let clippedCount: Int     // samples whose post-gain magnitude ≥ 1.0
    }

    private func resample(buffer: AVAudioPCMBuffer) -> ResampleResult {
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
                return ResampleResult(samples: [], preGainPeak: 0, postGainPeak: 0, clippedCount: 0)
            }
            sourceFormat = bufFormat
            targetFormat = target
            converter = AVAudioConverter(from: bufFormat, to: target)
            log.info("whisper converter ready: \(bufFormat.sampleRate, format: .fixed(precision: 0))Hz x \(bufFormat.channelCount)ch -> 16kHz mono")
        }
        guard let converter, let target = targetFormat else {
            convertLock.unlock()
            return ResampleResult(samples: [], preGainPeak: 0, postGainPeak: 0, clippedCount: 0)
        }
        convertLock.unlock()

        let outCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * target.sampleRate / bufFormat.sampleRate + 64
        )
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            return ResampleResult(samples: [], preGainPeak: 0, postGainPeak: 0, clippedCount: 0)
        }
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
            return ResampleResult(samples: [], preGainPeak: 0, postGainPeak: 0, clippedCount: 0)
        }
        // Apply software gain on the way out. VPIO's AGC tends to leave
        // float samples peaking far below ±1.0; this gives Whisper the
        // full-range audio its training distribution expects. Clip
        // hard at ±1.0 to keep loud audio from wrapping.
        //
        // Track pre-gain and post-gain-pre-clip peaks + a clip counter
        // in the same single pass so the dev audio-levels HUD has zero
        // extra cost on the audio render thread when the toggle is off.
        let frameCount = Int(out.frameLength)
        var samples = [Float](repeating: 0, count: frameCount)
        let gain = Self.SoftwareGain
        var preGainPeak: Float = 0
        var postGainPeak: Float = 0
        var clippedCount = 0
        for i in 0..<frameCount {
            let raw = channelData[i]
            let absRaw = abs(raw)
            if absRaw > preGainPeak { preGainPeak = absRaw }
            let amplified = raw * gain
            let absAmp = abs(amplified)
            if absAmp > postGainPeak { postGainPeak = absAmp }
            if absAmp >= 1.0 { clippedCount += 1 }
            samples[i] = max(-1.0, min(1.0, amplified))
        }
        return ResampleResult(
            samples: samples,
            preGainPeak: preGainPeak,
            postGainPeak: postGainPeak,
            clippedCount: clippedCount
        )
    }
}
#endif
