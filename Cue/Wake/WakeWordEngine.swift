#if os(iOS)
import AVFoundation
import Foundation
import OSLog

/// On-device wake-word detector for "Hey Cue", powered by sherpa-onnx's
/// streaming keyword spotter (KWS Zipformer). Consumes raw mic buffers
/// from `MicCapture.shared` so the input bus is shared cleanly with the
/// rest of the app — MicCapture owns the AVAudioEngine + tap, we just
/// register a buffer handler and feed samples to the spotter.
final class WakeWordEngine: @unchecked Sendable {

    /// Fires whenever the wake phrase is recognised (already on @MainActor).
    /// Reassign or clear by setting to nil. Debounced by `Debounce` seconds.
    var onDetect: (@MainActor () -> Void)?

    enum State { case idle, listening, denied, failed(String) }
    private(set) var state: State = .idle

    // MARK: - Tunables
    private static let Debounce: TimeInterval = 1.5
    private static let TargetSampleRate: Double = 16_000
    private static let FeatureDim: Int = 80
    /// Lower threshold = more sensitive (more hits, more false positives).
    /// 0.25 is the upstream default. In DEBUG we crank it down so we can see
    /// what the spotter is actually scoring.
    #if DEBUG
    private static let KeywordsThreshold: Float = 0.05
    #else
    private static let KeywordsThreshold: Float = 0.25
    #endif
    /// When true, the spotter logs a per-second heartbeat (samples/s, RMS,
    /// decode count). Useful when wake-word isn't firing and you want to
    /// confirm audio is reaching the engine. Flip to false to silence.
    private static let VerboseDiag: Bool = true

    // MARK: - Inference
    private let queue = DispatchQueue(label: "cue.wake.kws", qos: .userInitiated)
    private var spotter: SherpaOnnxKeywordSpotterWrapper?
    private var lastFireAt: Date = .distantPast

    // MARK: - Diagnostics (DEBUG)
    /// Per-second heartbeat: how many samples have been fed, accumulated
    /// sum-of-squares for RMS, and decode count since the last log.
    private var diagWindowStartedAt: Date = Date()
    private var diagSamplesFed: Int = 0
    private var diagSumSquares: Double = 0
    private var diagDecodeCount: Int = 0

    // MARK: - Converter (built lazily once we see the first buffer)
    private let convertLock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?

    // MARK: - Mic subscription
    private var bufferToken: UUID?

    private let log = Logger(subsystem: "app.cue", category: "wake")

    // MARK: - Public lifecycle

    /// Register a handler on `MicCapture.shared`. Idempotent. The mic
    /// itself is started/stopped by AppState based on playback — we just
    /// listen to whatever it delivers.
    @MainActor
    func start() {
        guard bufferToken == nil else { return }
        queue.async { [weak self] in
            self?.bootIfNeeded()
            self?.resetDiag()
        }
        bufferToken = MicCapture.shared.addBufferHandler { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        state = .listening
        log.info("wake handler registered")
    }

    @MainActor
    func stop() {
        if let token = bufferToken {
            MicCapture.shared.removeBufferHandler(token)
            bufferToken = nil
        }
        if case .listening = state { state = .idle }
        log.info("wake handler unregistered")
    }

    // MARK: - Internals

    private func bootIfNeeded() {
        guard spotter == nil else { return }

        guard
            let encoder = bundleURL("encoder.int8", ext: "onnx"),
            let decoder = bundleURL("decoder.int8", ext: "onnx"),
            let joiner  = bundleURL("joiner.int8",  ext: "onnx"),
            let tokens  = bundleURL("tokens",       ext: "txt"),
            let bpe     = bundleURL("bpe",          ext: "model"),
            let kw      = Bundle.main.url(forResource: "keywords", withExtension: "txt")
        else {
            let missing = "kws model resources not found in bundle"
            log.error("\(missing)")
            DispatchQueue.main.async { self.state = .failed(missing) }
            return
        }

        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: encoder.path,
            decoder: decoder.path,
            joiner:  joiner.path
        )
        let model = sherpaOnnxOnlineModelConfig(
            tokens: tokens.path,
            transducer: transducer,
            numThreads: 1,
            provider: "cpu",
            debug: 0,
            modelType: "",
            modelingUnit: "bpe",
            bpeVocab: bpe.path
        )
        let feat = sherpaOnnxFeatureConfig(
            sampleRate: Int(Self.TargetSampleRate),
            featureDim: Self.FeatureDim
        )
        var config = sherpaOnnxKeywordSpotterConfig(
            featConfig: feat,
            modelConfig: model,
            keywordsFile: kw.path,
            keywordsScore: 1.5,
            keywordsThreshold: Self.KeywordsThreshold
        )
        spotter = withUnsafePointer(to: &config) { SherpaOnnxKeywordSpotterWrapper(config: $0) }
        log.info("kws spotter ready — threshold=\(Self.KeywordsThreshold)")
    }

    /// Called on MicCapture's handler thread (AVAudioEngine input thread).
    private func handle(buffer: AVAudioPCMBuffer) {
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
                return
            }
            sourceFormat = bufFormat
            targetFormat = target
            converter = AVAudioConverter(from: bufFormat, to: target)
            log.info("wake converter ready: \(bufFormat.sampleRate, format: .fixed(precision: 0))Hz x \(bufFormat.channelCount)ch -> 16kHz mono")
        }
        guard let converter, let target = targetFormat else {
            convertLock.unlock()
            return
        }
        convertLock.unlock()

        let outCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * target.sampleRate / bufFormat.sampleRate + 64
        )
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var fed = false
        let status = converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }

        guard status != .error, let channelData = out.floatChannelData?[0] else {
            if let error { log.error("convert: \(error.localizedDescription)") }
            return
        }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(out.frameLength)))
        queue.async { [weak self] in self?.feed(samples: samples) }
    }

    private func feed(samples: [Float]) {
        guard let spotter else { return }
        spotter.acceptWaveform(samples: samples, sampleRate: Int(Self.TargetSampleRate))

        // Diagnostic accumulators: count samples and sum-of-squares for RMS.
        if Self.VerboseDiag {
            diagSamplesFed += samples.count
            var sumSq: Double = 0
            for s in samples { sumSq += Double(s) * Double(s) }
            diagSumSquares += sumSq
        }

        var decodesThisCall = 0
        while spotter.isReady() {
            spotter.decode()
            decodesThisCall += 1
        }
        if Self.VerboseDiag { diagDecodeCount += decodesThisCall }

        let result = spotter.getResult()
        let hit = result.keyword

        if !hit.isEmpty {
            // Reset the stream so the same phrase doesn't re-match from
            // residual internal state.
            let tokens = result.tokens.joined(separator: " ")
            spotter.reset()

            let now = Date()
            if now.timeIntervalSince(lastFireAt) < Self.Debounce {
                log.info("wake hit (debounced): keyword='\(hit)' tokens='\(tokens)'")
            } else {
                lastFireAt = now
                log.info("wake hit: keyword='\(hit)' tokens='\(tokens)'")
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onDetect?() }
                }
            }
        }

        // Heartbeat every ~1s: how much audio we've fed, its RMS (loudness
        // proxy), and how many decodes ran. Lets you watch the input live
        // and confirm the spotter is actually consuming it.
        if Self.VerboseDiag {
            let now = Date()
            let elapsed = now.timeIntervalSince(diagWindowStartedAt)
            if elapsed >= 1.0 {
                let sps = Int(Double(diagSamplesFed) / elapsed)
                let rms: Double = diagSamplesFed > 0
                    ? (diagSumSquares / Double(diagSamplesFed)).squareRoot()
                    : 0
                let rmsDb = rms > 0 ? 20 * log10(rms) : -120
                log.info("wake heartbeat — \(sps) samples/s, RMS=\(rms, format: .fixed(precision: 4)) (\(rmsDb, format: .fixed(precision: 1)) dBFS), decodes=\(self.diagDecodeCount)")
                diagWindowStartedAt = now
                diagSamplesFed = 0
                diagSumSquares = 0
                diagDecodeCount = 0
            }
        }
    }

    private func resetDiag() {
        diagWindowStartedAt = Date()
        diagSamplesFed = 0
        diagSumSquares = 0
        diagDecodeCount = 0
    }

    private func bundleURL(_ name: String, ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "kws-model")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }
}
#endif
