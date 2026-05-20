#if os(iOS)
//
//  WhisperKwsEngine.swift
//  Cue
//
//  WakeEngine implementation using whisper-tiny CoreML forced-decode
//  (sliding-window-max teacher-forced decoding). Drop-in replacement for
//  `WakeWordEngine` behind the `cue.forceDecodeWakeEnabled` toggle.
//
//  Mic plumbing (rolling 16 kHz ring buffer, resampling, level tracking,
//  throttled inference, debounce) is intentionally a near-copy of
//  `WakeWordEngine` — the differences live in the inference step.
//
//  Per inference round:
//    1. Snapshot the rolling 2 s window of 16 kHz mono float audio.
//    2. Score only the newest 0.8 s slice. Earlier versions rescored all
//       seven overlapping 0.8 s / 0.2 s windows in the 2 s buffer every
//       tick; that repeated work faster than real time on device.
//       Successive ticks provide the sliding-window coverage instead.
//    3. If any keyword scores ≥ threshold, fire `onDetect` (debounced).
//
//  The "transcript" surfaced via `onTranscript` is a synthesised line like
//  `orbit -5.42/-7.00` (best variant + score/threshold) so the dev tracking
//  HUD still shows readable evidence of what the engine is seeing.
//

@preconcurrency import AVFoundation
import Foundation
import OSLog

final class WhisperKwsEngine: WakeEngine, @unchecked Sendable {

    // MARK: - WakeEngine surface

    var onDetect: (@MainActor () -> Void)?
    var onTranscript: (@MainActor (_ text: String, _ isHit: Bool, _ levels: AudioLevelStats?) -> Void)?

    enum State { case idle, loading, listening, denied, failed(String) }
    private(set) var state: State = .idle

    // MARK: - Tunables (parallel WakeWordEngine constants where it makes sense)

    nonisolated private static let TargetSampleRate: Double = 16_000
    nonisolated private static let WindowSeconds: Double = 2.0
    nonisolated private static let WindowSamples: Int = Int(16_000 * 2)
    nonisolated private static let ScoringWindowSeconds: Double = 0.8
    nonisolated private static let ScoringWindowSamples: Int = Int(16_000 * 0.8)
    /// Inference cadence. This is slightly faster than the scorer's 0.2 s stride,
    /// leaving headroom for one forced-decode window on device.
    nonisolated private static let InferenceIntervalMs: Int = 150
    nonisolated private static let MinAudioMs: Int = 200
    nonisolated private static let Debounce: TimeInterval = 1.5
    nonisolated private static let StatusTranscriptInterval: TimeInterval = 1.0

    /// Software gain applied to resampled samples. Same rationale as
    /// `WakeWordEngine`: VPIO's AGC leaves samples peaking at ±0.1–0.2;
    /// boost 3× to land in Whisper's training distribution.
    nonisolated private static let SoftwareGain: Float = 3.0
    /// Silence padding (ms) prepended to each inference window. Forced-decode
    /// doesn't strictly need this, but the encoder is shape-fixed at 30 s
    /// regardless — the pad is internal to the scorer.
    nonisolated private static let LeadingSilencePadMs: Int = 0

    /// Keywords scored each round. Match the trigger variants in
    /// `WakeWordEngine.TriggerPattern` so user-facing copy stays consistent.
    nonisolated private static let Keywords: [String] = ["orbit", "orbital", "orbits"]
    /// Score threshold. Onit-beacon's permissive default is −8.0 for
    /// transcript rescore (where the perplexity gate filters FPs). Wake-word
    /// has no second stage, so we ship slightly stricter at −7.0 and expect
    /// to recalibrate with real-device dogfood data.
    static let Threshold: Float = -7.0

    static let userVisibleTriggers = "orbit / orbital / orbits"

    // MARK: - State

    nonisolated(unsafe) private var lastFireAt: Date = .distantPast
    nonisolated private let stateLock = NSLock()
    nonisolated(unsafe) private var lastInferenceAt: Date = .distantPast
    nonisolated(unsafe) private var lastStatusTranscriptAt: Date = .distantPast
    nonisolated(unsafe) private var lastBackpressureLogAt: Date = .distantPast
    nonisolated(unsafe) private var inferenceInFlight: Bool = false
    nonisolated(unsafe) private var skippedWhileInFlight: Int = 0
    nonisolated(unsafe) private var scorerReady: Bool = false
    nonisolated(unsafe) private var scorerFailureMessage: String?
    nonisolated(unsafe) private var lifecycleGeneration: UInt64 = 0

    // Rolling 16 kHz mono buffer.
    nonisolated private let bufLock = NSLock()
    nonisolated(unsafe) private var rolling = RingBuffer<Float>(capacity: WindowSamples, fill: 0)

    // Per-window audio level stats — same pattern as WakeWordEngine.
    nonisolated(unsafe) private var windowPreGainPeak: Float = 0
    nonisolated(unsafe) private var windowPostGainPeak: Float = 0
    nonisolated(unsafe) private var windowClippedCount: Int = 0
    nonisolated(unsafe) private var windowSampleCount: Int = 0

    // Mic subscription / resampler.
    private var bufferToken: UUID?
    private var bootTask: Task<Void, Never>?
    nonisolated private let convertLock = NSLock()
    nonisolated(unsafe) private var converter: AVAudioConverter?
    nonisolated(unsafe) private var sourceFormat: AVAudioFormat?
    nonisolated(unsafe) private var targetFormat: AVAudioFormat?

    private let log = Logger(subsystem: "app.cue", category: "wakeKWS")

    // MARK: - Public lifecycle

    @MainActor
    func start() {
        guard bufferToken == nil else { return }
        let generation = advanceLifecycleGeneration()
        loadScorerIfNeeded(generation: generation)
        bufferToken = MicCapture.shared.addBufferHandler { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        state = .listening
        onTranscript?(Self.statusTranscriptText(for: nil), false, nil)
        log.info("kws wake handler registered")
    }

    @MainActor
    func stop() {
        bootTask?.cancel()
        bootTask = nil
        if let token = bufferToken {
            MicCapture.shared.removeBufferHandler(token)
            bufferToken = nil
        }
        bufLock.lock()
        rolling.removeAll()
        windowPreGainPeak = 0
        windowPostGainPeak = 0
        windowClippedCount = 0
        windowSampleCount = 0
        bufLock.unlock()
        stateLock.lock()
        lifecycleGeneration += 1
        lastInferenceAt = .distantPast
        lastStatusTranscriptAt = .distantPast
        inferenceInFlight = false
        stateLock.unlock()
        if case .listening = state { state = .idle }
        log.info("kws wake handler unregistered")
    }

    // MARK: - Scorer boot

    @MainActor
    private func loadScorerIfNeeded(generation: UInt64) {
        if scorerReady { return }
        if case .loading = state { return }
        state = .loading
        log.info("kws scorer loading…")
        bootTask = Task.detached(priority: .userInitiated) { [weak self] in
            let started = DispatchTime.now()
            do {
                try await WhisperKwsScorer.shared.loadIfNeeded(keywords: WhisperKwsEngine.Keywords)
                try Task.checkCancellation()
                guard let self, self.isGenerationCurrent(generation) else { return }
                let loadMs = Self.elapsedMs(since: started)
                let warmStarted = DispatchTime.now()
                try await WhisperKwsScorer.shared.warmUp(sampleCount: WhisperKwsEngine.ScoringWindowSamples)
                try Task.checkCancellation()
                guard self.isGenerationCurrent(generation) else { return }
                let warmMs = Self.elapsedMs(since: warmStarted)
                await self.handleScorerReady(loadMs: loadMs, warmMs: warmMs, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                let msg = error.localizedDescription
                let loadMs = Self.elapsedMs(since: started)
                await self?.handleScorerLoadFailure(msg, loadMs: loadMs, generation: generation)
            }
        }
    }

    @MainActor
    private func handleScorerReady(loadMs: Double, warmMs: Double, generation: UInt64) {
        guard isGenerationCurrent(generation) else { return }
        bootTask = nil
        scorerReady = true
        if bufferToken != nil {
            state = .listening
        } else {
            state = .idle
        }
        log.info("kws scorer ready in \(Self.ms(loadMs), privacy: .public), warmup=\(Self.ms(warmMs), privacy: .public)")
    }

    @MainActor
    private func handleScorerLoadFailure(_ msg: String, loadMs: Double, generation: UInt64) {
        guard isGenerationCurrent(generation) else { return }
        bootTask = nil
        state = .failed(msg)
        stateLock.lock()
        scorerFailureMessage = msg
        stateLock.unlock()
        onTranscript?(Self.statusTranscriptText(for: msg), false, nil)
        log.error("kws scorer load failed after \(Self.ms(loadMs), privacy: .public): \(msg, privacy: .public)")
    }

    // MARK: - Audio path (audio render thread)

    private nonisolated func handle(buffer: AVAudioPCMBuffer) {
        let resampleStarted = DispatchTime.now()
        let result = resample(buffer: buffer)
        let resampleMs = Self.elapsedMs(since: resampleStarted)
        if resampleMs >= 10 {
            log.debug("kws timing audio: resample=\(Self.ms(resampleMs), privacy: .public) inputFrames=\(buffer.frameLength, privacy: .public) outputSamples=\(result.samples.count, privacy: .public)")
        }
        guard !result.samples.isEmpty else { return }

        bufLock.lock()
        result.samples.withUnsafeBufferPointer { rolling.pushBack($0) }
        if result.preGainPeak > windowPreGainPeak { windowPreGainPeak = result.preGainPeak }
        if result.postGainPeak > windowPostGainPeak { windowPostGainPeak = result.postGainPeak }
        windowClippedCount += result.clippedCount
        windowSampleCount += result.samples.count
        let availableCount = rolling.count
        bufLock.unlock()

        let minSamples = Int(Self.TargetSampleRate * Double(Self.MinAudioMs) / 1000.0)
        guard availableCount >= minSamples else { return }

        let now = Date()
        stateLock.lock()
        let dueMs = now.timeIntervalSince(lastInferenceAt) * 1000
        let intervalMs = Double(Self.InferenceIntervalMs)
        let ready = scorerReady
        let failureMessage = scorerFailureMessage
        let generation = lifecycleGeneration
        let shouldEmitStatus = !ready && now.timeIntervalSince(lastStatusTranscriptAt) >= Self.StatusTranscriptInterval
        if shouldEmitStatus {
            lastStatusTranscriptAt = now
        }
        if dueMs < intervalMs || inferenceInFlight || !ready {
            if inferenceInFlight && dueMs >= intervalMs {
                skippedWhileInFlight += 1
                if now.timeIntervalSince(lastBackpressureLogAt) >= Self.StatusTranscriptInterval {
                    let skipped = skippedWhileInFlight
                    skippedWhileInFlight = 0
                    lastBackpressureLogAt = now
                    log.debug("kws timing backpressure: skipped=\(skipped, privacy: .public) dueMs=\(Self.ms(dueMs), privacy: .public)")
                }
            }
            stateLock.unlock()
            if shouldEmitStatus {
                emitStatusTranscript(Self.statusTranscriptText(for: failureMessage))
            }
            return
        }
        lastInferenceAt = now
        inferenceInFlight = true
        skippedWhileInFlight = 0
        stateLock.unlock()

        let snapshotStarted = DispatchTime.now()
        bufLock.lock()
        let snapshot = rolling.snapshot()
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
        let inferenceSamples = snapshot.count > Self.ScoringWindowSamples
            ? Array(snapshot.suffix(Self.ScoringWindowSamples))
            : snapshot
        let snapshotMs = Self.elapsedMs(since: snapshotStarted)
        let scheduledAt = DispatchTime.now()

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runInference(
                samples: inferenceSamples,
                levels: levels,
                scheduledAt: scheduledAt,
                snapshotMs: snapshotMs,
                ringSampleCount: snapshot.count,
                generation: generation
            )
            self?.markInferenceComplete(generation: generation)
        }
    }

    private nonisolated func runInference(
        samples: [Float],
        levels: AudioLevelStats?,
        scheduledAt: DispatchTime,
        snapshotMs: Double,
        ringSampleCount: Int,
        generation: UInt64
    ) async {
        guard !Task.isCancelled, isGenerationCurrent(generation) else { return }
        let started = DispatchTime.now()
        let queueMs = Self.elapsedMs(since: scheduledAt)
        // Optional leading silence pad (currently 0 — forced-decode handles
        // padding internally inside the mel call).
        let padStarted = DispatchTime.now()
        let padSamples = Int(Self.TargetSampleRate * Double(Self.LeadingSilencePadMs) / 1000.0)
        let padded: [Float] = padSamples > 0
            ? Array(repeating: Float(0), count: padSamples) + samples
            : samples
        let padMs = Self.elapsedMs(since: padStarted)
        do {
            let scoreStarted = DispatchTime.now()
            let scores = try await WhisperKwsScorer.shared.maxScores(in: padded)
            guard !Task.isCancelled, isGenerationCurrent(generation) else { return }
            let scoreMs = Self.elapsedMs(since: scoreStarted)
            guard let best = scores.max(by: { $0.score < $1.score }) else { return }
            let mainStarted = DispatchTime.now()
            await MainActor.run {
                guard self.isGenerationCurrent(generation) else { return }
                self.handleScores(scores, best: best, levels: levels)
            }
            let mainMs = Self.elapsedMs(since: mainStarted)
            let totalMs = Self.elapsedMs(since: started)
            log.debug("kws timing engine: total=\(Self.ms(totalMs), privacy: .public) queue=\(Self.ms(queueMs), privacy: .public) snapshot=\(Self.ms(snapshotMs), privacy: .public) pad=\(Self.ms(padMs), privacy: .public) scorer=\(Self.ms(scoreMs), privacy: .public) samples=\(samples.count, privacy: .public) ringSamples=\(ringSampleCount, privacy: .public) main=\(Self.ms(mainMs), privacy: .public) best=\(best.keyword, privacy: .public) \(Self.score(best.score), privacy: .public)")
        } catch {
            guard isGenerationCurrent(generation) else { return }
            let msg = error.localizedDescription
            let totalMs = Self.elapsedMs(since: started)
            log.error("kws inference failed after \(Self.ms(totalMs), privacy: .public): \(msg, privacy: .public)")
            await MainActor.run {
                guard self.isGenerationCurrent(generation) else { return }
                self.onTranscript?(Self.statusTranscriptText(for: msg), false, levels)
            }
        }
    }

    @MainActor
    private func handleScores(_ scores: [WhisperKwsScore], best: WhisperKwsScore, levels: AudioLevelStats?) {
        let aboveThreshold = best.score >= Self.Threshold
        let now = Date()
        let shouldFire = aboveThreshold && now.timeIntervalSince(lastFireAt) >= Self.Debounce

        // Synthesize a transcript-like string for the dev HUD. Same surface
        // contract as WakeWordEngine.onTranscript so the toast stack works
        // unchanged.
        let display = String(format: "%@ %.2f/%.2f", best.keyword, best.score, Self.Threshold)
        onTranscript?(display, shouldFire, levels)

        guard aboveThreshold else { return }

        guard shouldFire else {
            log.info("kws hit (debounced): \(display, privacy: .public)")
            return
        }
        lastFireAt = now
        log.info("kws hit: \(display, privacy: .public)")
        onDetect?()
    }

    // MARK: - Resampler (audio render thread)
    //
    // Identical structure to WakeWordEngine.resample — duplicated rather
    // than factored so the two engines have zero shared mutable state.

    private struct ResampleResult {
        let samples: [Float]
        let preGainPeak: Float
        let postGainPeak: Float
        let clippedCount: Int
    }

    private nonisolated func emitStatusTranscript(_ text: String) {
        let levels = snapshotAndResetLevels()
        Task { @MainActor [weak self] in
            self?.onTranscript?(text, false, levels)
        }
    }

    private nonisolated func snapshotAndResetLevels() -> AudioLevelStats? {
        bufLock.lock()
        defer { bufLock.unlock() }
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
        return levels
    }

    private nonisolated static func statusTranscriptText(for message: String?) -> String {
        guard let message, !message.isEmpty else {
            return "kws loading..."
        }
        if message.contains("resource missing") || message.contains("resource not found") {
            return "kws assets missing"
        }
        return "kws unavailable: \(String(message.prefix(80)))"
    }

    private nonisolated static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private nonisolated static func ms(_ value: Double) -> String {
        String(format: "%.1fms", value)
    }

    private nonisolated static func score(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    private nonisolated func advanceLifecycleGeneration() -> UInt64 {
        stateLock.lock()
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        stateLock.unlock()
        return generation
    }

    private nonisolated func isGenerationCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock()
        let current = lifecycleGeneration
        stateLock.unlock()
        return current == generation
    }

    private nonisolated func markInferenceComplete(generation: UInt64) {
        stateLock.lock()
        if lifecycleGeneration == generation {
            inferenceInFlight = false
        }
        stateLock.unlock()
    }

    private nonisolated func resample(buffer: AVAudioPCMBuffer) -> ResampleResult {
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
            log.info("kws converter ready: \(bufFormat.sampleRate, format: .fixed(precision: 0))Hz x \(bufFormat.channelCount)ch -> 16kHz mono")
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
            if let error { log.error("kws convert: \(error.localizedDescription, privacy: .public)") }
            return ResampleResult(samples: [], preGainPeak: 0, postGainPeak: 0, clippedCount: 0)
        }
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
