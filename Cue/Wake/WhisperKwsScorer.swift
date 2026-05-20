#if os(iOS)
//
//  WhisperKwsScorer.swift
//  Cue
//
//  Sliding-window whisper-tiny CoreML forced-decode scorer. Adapted from
//  onit-beacon (macos/Onit/Transcription/CustomDictionary/WhisperKwsService.swift)
//  for the wake-word use case: fixed keyword set, score-only API (no peak
//  walking, no per-term thresholds, no integration with a rescore pipeline).
//
//  Algorithm — for each audio buffer (typically the rolling 2 s wake window):
//    1. Slide a 0.8 s window with 0.2 s stride.
//    2. Per window:
//         a. Pad audio to 30 s @ 16 kHz, run MelSpectrogram + AudioEncoderTiny
//            (encoder hidden states [1,384,1,1500]).
//         b. Slice encoder output to first K=80 frames (decoder cross-attn
//            crop — 5-10× speedup, no recall loss).
//         c. Build decoder input [B=64, T=8] with
//            [<sot><en><transcribe><notimestamps>] + phrase_tokens, EOT-padded.
//            One row per keyword variant, batched in one decoder call.
//         d. Forced-decode → mean log-prob over phrase tokens per row.
//    3. Per keyword: max score across windows. Return the best.
//
//  Compute units: mel on CPU, encoder on GPU, decoder on ANE — different
//  devices so encoder(window k+1) overlaps with decoder(window k).
//  Vectorized log-softmax via vImage + vDSP + vvexpf.
//
//  See:
//    - ~/Documents/Apps/onit-beacon/macos/Onit/Resources/WhisperKWS/LATENCY-HANDOFF.md
//      for the perf trail and what NOT to change.
//    - ~/Documents/Harold/Onit/lenardo-kws-research/EXPLORATION-2026-04-29.md
//      for the algorithm rationale.
//

import Accelerate
import CoreML
import Foundation
import os.log

nonisolated private let scorerLog = Logger(subsystem: "app.cue", category: "whisperKWS")

/// Unchecked-Sendable wrapper for handing CoreML objects across `Task`
/// boundaries. `MLMultiArray` and `MLModel` are documented as thread-safe
/// for prediction; the wrapper just appeases Swift 6's strict concurrency.
private struct UnsafeSend<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T
}

private struct WhisperKwsEncodedWindow: @unchecked Sendable {
    nonisolated(unsafe) let encoderOutput: MLMultiArray
    let copyMs: Double
    let melMs: Double
    let encoderMs: Double
    let sliceMs: Double
    let totalMs: Double
}

private struct WhisperKwsDecodeScores {
    let scores: [Float]
    let inputMs: Double
    let predictionMs: Double
    let postprocessMs: Double
    let totalMs: Double
}

enum WhisperKwsScorerError: LocalizedError {
    case notLoaded
    case modelFilesNotFound(String)
    case tokenizationFailed(String)
    case inferenceError(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "Whisper KWS model not loaded — call loadIfNeeded first"
        case .modelFilesNotFound(let name):
            return "Whisper KWS resource missing from bundle: \(name)"
        case .tokenizationFailed(let m):
            return "Whisper KWS keyword tokenization failed: \(m)"
        case .inferenceError(let m):
            return "Whisper KWS inference error: \(m)"
        }
    }
}

/// Per-keyword max-window score for one buffer evaluation.
struct WhisperKwsScore: Sendable {
    let keyword: String
    /// Mean log-prob over phrase tokens for the best window. Higher (less
    /// negative) = stronger match.
    let score: Float
}

/// Sliding-window forced-decode scorer. Single shared instance per process
/// (model load is expensive; the CoreML graphs are ~84 MB combined).
actor WhisperKwsScorer {

    static let shared = WhisperKwsScorer()
    private init() {}

    // MARK: - Constants (mirror onit-beacon's WhisperKwsService)

    /// Sliding window length in seconds.
    static let windowSec: Double = 0.8
    /// Hop between successive windows. 0.2 s — onit-beacon regression-tested
    /// that 0.3+ misses real keyword placements.
    static let strideSec: Double = 0.2
    /// Whisper-tiny d_model.
    private static let encoderHidden: Int = 384
    /// Sample rate the underlying CoreML graph was traced at.
    private static let sampleRate: Int = 16_000
    /// Whisper input audio buffer length: 30 s × 16 kHz.
    private static let audioPadSamples: Int = 480_000
    /// Whisper-tiny encoder timeline length (frames).
    private static let encoderFrames: Int = 1500
    /// Decoder prefix tokens
    /// (`<|startoftranscript|><|en|><|transcribe|><|notimestamps|>`).
    private static let decoderPrefixCount: Int = 4
    /// Static decoder batch dimension. The CoreML graph is traced at this
    /// fixed shape so it compiles to ANE+GPU; flexibility (EnumeratedShapes)
    /// pins the 1050-op graph to CPU and is ~25× slower.
    private static let decoderBatch: Int = 64
    /// Static decoder sequence length. Holds prefix (4) + up to 4 phrase
    /// BPE tokens.
    private static let decoderSeqLen: Int = 8
    /// Whisper end-of-text token, used as filler at unused decoder positions.
    private static let eotTokenId: Int32 = 50257
    /// Whisper-base vocab size (multilingual). Same on tiny — only depth differs.
    private static let vocabSize: Int = 51865
    /// Decoder cross-attention encoder context length. The decoder graph
    /// is traced with K=80 (1.6 s of encoder frames) instead of the full
    /// K=1500 (30 s). Cropping cuts decoder cost ~5-10× with no recall
    /// regression on onit-beacon's dictation suite.
    private static let decoderEncoderContext: Int = 80

    // MARK: - Loaded state

    private var melModel: MLModel?
    private var encoderModel: MLModel?
    private var decoderModel: MLModel?

    /// Per-keyword cache: original text + tokenized form (incl. decoder prefix).
    private var keywordTokens: [(keyword: String, tokenIds: [Int])] = []
    /// Hash of the keyword set; lets `loadIfNeeded` no-op on repeated calls
    /// with the same input.
    private var loadedHash: Int = 0

    var isLoaded: Bool {
        melModel != nil && encoderModel != nil && decoderModel != nil && !keywordTokens.isEmpty
    }

    // MARK: - Public API

    /// Load (or reload) the scorer with the given keyword strings. Each
    /// keyword is BPE-encoded and prepended with the decoder prefix. Safe
    /// to call repeatedly — no-ops when the keyword set is unchanged.
    func loadIfNeeded(keywords: [String]) async throws {
        let loadStarted = DispatchTime.now()
        guard !keywords.isEmpty else { return }

        var hasher = Hasher()
        keywords.forEach { hasher.combine($0) }
        let hash = hasher.finalize()
        guard loadedHash != hash else { return }

        var modelTimings: [String] = []

        // Lazily load the three CoreML models from the bundle.
        if melModel == nil {
            // Mel on CPU — sharing ANE with the decoder causes contention
            // (ANE serializes its dispatch queue) and breaks encoder/decoder
            // pipelining. CPU mel is ~1 ms/call, well within budget.
            let started = DispatchTime.now()
            melModel = try Self.loadModel(named: "MelSpectrogram", computeUnits: .cpuOnly)
            modelTimings.append("mel=\(Self.ms(Self.elapsedMs(since: started)))")
        }
        if encoderModel == nil {
            // Tiny encoder on GPU (5 ms) — the 13 ms ANE path is 2.6× slower
            // for whisper-tiny because dispatch overhead dominates compute.
            let started = DispatchTime.now()
            encoderModel = try Self.loadModel(named: "AudioEncoderTiny", computeUnits: .cpuAndGPU)
            modelTimings.append("encoder=\(Self.ms(Self.elapsedMs(since: started)))")
        }
        if decoderModel == nil {
            // Tiny decoder on ANE (8 ms) — paired with the encoder on GPU
            // so the two stages pipeline across different devices.
            let started = DispatchTime.now()
            decoderModel = try Self.loadModel(named: "TextDecoderParallelTiny", computeUnits: .cpuAndNeuralEngine)
            modelTimings.append("decoder=\(Self.ms(Self.elapsedMs(since: started)))")
        }

        let tokenStarted = DispatchTime.now()
        var newTokens: [(keyword: String, tokenIds: [Int])] = []
        for keyword in keywords {
            do {
                let ids = try await WhisperBPETokenizer.shared.encode(keyword, withDecoderPrefix: true)
                guard ids.count > Self.decoderPrefixCount else {
                    throw WhisperKwsScorerError.tokenizationFailed(
                        "keyword '\(keyword)' produced no body tokens after decoder prefix"
                    )
                }
                guard ids.count <= Self.decoderSeqLen else {
                    throw WhisperKwsScorerError.tokenizationFailed(
                        "keyword '\(keyword)' tokenized to \(ids.count) tokens "
                        + "(static parallel decoder fits \(Self.decoderSeqLen))"
                    )
                }
                newTokens.append((keyword: keyword, tokenIds: ids))
            } catch let e as WhisperKwsScorerError {
                throw e
            } catch {
                throw WhisperKwsScorerError.tokenizationFailed(
                    "keyword '\(keyword)': \(error.localizedDescription)"
                )
            }
        }
        let tokenMs = Self.elapsedMs(since: tokenStarted)

        self.keywordTokens = newTokens
        self.loadedHash = hash
        let totalMs = Self.elapsedMs(since: loadStarted)
        scorerLog.debug("kws timing load: total=\(Self.ms(totalMs), privacy: .public) models=\(modelTimings.joined(separator: " "), privacy: .public) tokenize=\(Self.ms(tokenMs), privacy: .public) keywords=\(newTokens.count, privacy: .public)")
    }

    /// Run one silent single-window inference after model load so CoreML pays
    /// its first-prediction setup cost before the wake engine starts listening.
    func warmUp(sampleCount: Int) async throws {
        guard sampleCount > 0 else { return }
        guard isLoaded else { throw WhisperKwsScorerError.notLoaded }
        let started = DispatchTime.now()
        _ = try await maxScores(in: Array(repeating: 0, count: sampleCount))
        scorerLog.debug("kws timing warmup: total=\(Self.ms(Self.elapsedMs(since: started)), privacy: .public) samples=\(sampleCount, privacy: .public)")
    }

    /// Run the sliding-window scorer on `samples` (Float32, 16 kHz, mono).
    /// Returns per-keyword max-window scores (one entry per registered keyword).
    func maxScores(in samples: [Float]) async throws -> [WhisperKwsScore] {
        let totalStarted = DispatchTime.now()
        guard isLoaded else { throw WhisperKwsScorerError.notLoaded }
        guard !samples.isEmpty else { return [] }

        let setupStarted = DispatchTime.now()
        let windowSamples = Int(Self.windowSec * Double(Self.sampleRate))
        let strideSamples = max(1, Int(Self.strideSec * Double(Self.sampleRate)))
        let lastStart = max(0, samples.count - windowSamples)

        var windowStarts: [Int] = []
        var s = 0
        while s <= lastStart {
            windowStarts.append(s)
            if s == lastStart { break }
            s = min(s + strideSamples, lastStart)
        }
        // Buffers shorter than one window: score the whole thing once,
        // zero-padded inside the mel call. Better than returning empty.
        if windowStarts.isEmpty { windowStarts = [0] }
        let setupMs = Self.elapsedMs(since: setupStarted)

        guard let melModel = self.melModel,
              let encoderModel = self.encoderModel,
              let decoderModel = self.decoderModel else {
            throw WhisperKwsScorerError.notLoaded
        }
        let melSend = UnsafeSend(value: melModel)
        let encSend = UnsafeSend(value: encoderModel)
        let decSend = UnsafeSend(value: decoderModel)
        let kwTokens = self.keywordTokens
        let audioPad = Self.audioPadSamples
        let encoderContext = Self.decoderEncoderContext

        // Pipelined per-window encode + batched decode. Encoder runs on
        // GPU (detached Task), decoder runs on ANE — different devices
        // so they parallelize.
        func makeEncoderTask(_ start: Int) -> Task<WhisperKwsEncodedWindow, Error> {
            let copyStarted = DispatchTime.now()
            let end = min(start + windowSamples, samples.count)
            let windowAudio = Array(samples[start..<end])
            let copyMs = Self.elapsedMs(since: copyStarted)
            return Task.detached(priority: .userInitiated) {
                let totalStarted = DispatchTime.now()
                let melStarted = DispatchTime.now()
                let mel = try Self.runMelSpectrogramStatic(
                    model: melSend.value,
                    samples: windowAudio,
                    audioPadSamples: audioPad
                )
                let melMs = Self.elapsedMs(since: melStarted)
                let encoderStarted = DispatchTime.now()
                let encFull = try Self.runEncoderStatic(model: encSend.value, mel: mel)
                let encoderMs = Self.elapsedMs(since: encoderStarted)
                let sliceStarted = DispatchTime.now()
                let encSliced = try Self.sliceEncoderToContext(encFull, contextLen: encoderContext)
                let sliceMs = Self.elapsedMs(since: sliceStarted)
                return WhisperKwsEncodedWindow(
                    encoderOutput: encSliced,
                    copyMs: copyMs,
                    melMs: melMs,
                    encoderMs: encoderMs,
                    sliceMs: sliceMs,
                    totalMs: Self.elapsedMs(since: totalStarted)
                )
            }
        }

        // Tracks max score per keyword across all windows.
        var maxScoreByIdx: [Float] = Array(repeating: -.infinity, count: kwTokens.count)
        var encoderAwaitTotalMs: Double = 0
        var copyTotalMs: Double = 0
        var melTotalMs: Double = 0
        var encoderTotalMs: Double = 0
        var sliceTotalMs: Double = 0
        var encodeMaxMs: Double = 0
        var decoderInputTotalMs: Double = 0
        var decoderPredictTotalMs: Double = 0
        var decoderPostTotalMs: Double = 0
        var decoderTotalMs: Double = 0
        var decoderMaxMs: Double = 0

        var inFlight: Task<WhisperKwsEncodedWindow, Error>? = makeEncoderTask(windowStarts[0])
        for (i, _) in windowStarts.enumerated() {
            let awaitStarted = DispatchTime.now()
            let enc = try await inFlight!.value
            encoderAwaitTotalMs += Self.elapsedMs(since: awaitStarted)
            copyTotalMs += enc.copyMs
            melTotalMs += enc.melMs
            encoderTotalMs += enc.encoderMs
            sliceTotalMs += enc.sliceMs
            if enc.totalMs > encodeMaxMs { encodeMaxMs = enc.totalMs }
            if i + 1 < windowStarts.count {
                inFlight = makeEncoderTask(windowStarts[i + 1])
            } else {
                inFlight = nil
            }
            let decoded = try Self.forcedDecodeScoresStatic(
                model: decSend.value,
                keywordTokens: kwTokens,
                encoderOutput: enc.encoderOutput
            )
            decoderInputTotalMs += decoded.inputMs
            decoderPredictTotalMs += decoded.predictionMs
            decoderPostTotalMs += decoded.postprocessMs
            decoderTotalMs += decoded.totalMs
            if decoded.totalMs > decoderMaxMs { decoderMaxMs = decoded.totalMs }
            for (k, sc) in decoded.scores.enumerated() {
                if sc > maxScoreByIdx[k] { maxScoreByIdx[k] = sc }
            }
        }

        let totalMs = Self.elapsedMs(since: totalStarted)
        let bestScore = maxScoreByIdx.max() ?? -.infinity
        scorerLog.debug("kws timing scorer: total=\(Self.ms(totalMs), privacy: .public) windows=\(windowStarts.count, privacy: .public) samples=\(samples.count, privacy: .public) setup=\(Self.ms(setupMs), privacy: .public) awaitEncode=\(Self.ms(encoderAwaitTotalMs), privacy: .public) copy=\(Self.ms(copyTotalMs), privacy: .public) mel=\(Self.ms(melTotalMs), privacy: .public) encoder=\(Self.ms(encoderTotalMs), privacy: .public) slice=\(Self.ms(sliceTotalMs), privacy: .public) encodeMax=\(Self.ms(encodeMaxMs), privacy: .public) decoder=\(Self.ms(decoderTotalMs), privacy: .public) decInput=\(Self.ms(decoderInputTotalMs), privacy: .public) decPredict=\(Self.ms(decoderPredictTotalMs), privacy: .public) decPost=\(Self.ms(decoderPostTotalMs), privacy: .public) decMax=\(Self.ms(decoderMaxMs), privacy: .public) best=\(Self.score(bestScore), privacy: .public)")

        return zip(kwTokens, maxScoreByIdx).map { entry, score in
            WhisperKwsScore(keyword: entry.keyword, score: score)
        }
    }

    // MARK: - Inference helpers (static so they can run in detached Tasks)

    private static func runMelSpectrogramStatic(
        model: MLModel,
        samples: [Float],
        audioPadSamples: Int
    ) throws -> MLMultiArray {
        let audioMLA = try MLMultiArray(
            shape: [NSNumber(value: audioPadSamples)],
            dataType: .float16
        )
        let audioPtr = audioMLA.dataPointer.assumingMemoryBound(to: Float16.self)
        let copyCount = min(samples.count, audioPadSamples)

        // Vectorized Float32 -> Float16 via vImage.
        samples.withUnsafeBufferPointer { srcBuf in
            var srcImage = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: srcBuf.baseAddress!),
                height: 1,
                width: vImagePixelCount(copyCount),
                rowBytes: copyCount * MemoryLayout<Float>.size
            )
            var dstImage = vImage_Buffer(
                data: UnsafeMutableRawPointer(audioPtr),
                height: 1,
                width: vImagePixelCount(copyCount),
                rowBytes: copyCount * MemoryLayout<Float16>.size
            )
            vImageConvert_PlanarFtoPlanar16F(&srcImage, &dstImage, 0)
        }
        if copyCount < audioPadSamples {
            let tailBytes = (audioPadSamples - copyCount) * MemoryLayout<Float16>.size
            memset(audioPtr + copyCount, 0, tailBytes)
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio": MLFeatureValue(multiArray: audioMLA),
        ])
        let output = try model.prediction(from: input)
        guard let mel = output.featureValue(for: "melspectrogram_features")?.multiArrayValue else {
            throw WhisperKwsScorerError.inferenceError("MelSpectrogram: missing 'melspectrogram_features' output")
        }
        return mel
    }

    private static func runEncoderStatic(model: MLModel, mel: MLMultiArray) throws -> MLMultiArray {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "melspectrogram_features": MLFeatureValue(multiArray: mel),
        ])
        let output = try model.prediction(from: input)
        guard let enc = output.featureValue(for: "encoder_output_embeds")?.multiArrayValue else {
            throw WhisperKwsScorerError.inferenceError("AudioEncoder: missing 'encoder_output_embeds' output")
        }
        return enc
    }

    /// Slice the encoder output [1, H, 1, T] → [1, H, 1, contextLen].
    /// Allocates a fresh MLMultiArray; CoreML predict requires a contiguous
    /// input matching the traced shape (strided views won't work).
    private static func sliceEncoderToContext(
        _ enc: MLMultiArray,
        contextLen: Int
    ) throws -> MLMultiArray {
        let H = enc.shape[1].intValue
        let T = enc.shape[3].intValue
        guard contextLen <= T else {
            throw WhisperKwsScorerError.inferenceError(
                "encoder context \(contextLen) exceeds source \(T)"
            )
        }
        let out = try MLMultiArray(
            shape: [1, NSNumber(value: H), 1, NSNumber(value: contextLen)],
            dataType: .float16
        )
        let srcPtr = enc.dataPointer.assumingMemoryBound(to: Float16.self)
        let dstPtr = out.dataPointer.assumingMemoryBound(to: Float16.self)
        let srcS1 = enc.strides[1].intValue
        let srcS3 = enc.strides[3].intValue
        for h in 0..<H {
            let srcRow = srcPtr + h * srcS1
            let dstRow = dstPtr + h * contextLen
            if srcS3 == 1 {
                memcpy(dstRow, srcRow, contextLen * MemoryLayout<Float16>.size)
            } else {
                for t in 0..<contextLen {
                    dstRow[t] = srcRow[t * srcS3]
                }
            }
        }
        return out
    }

    /// Forced-decode every loaded keyword against `encoderOutput` in
    /// fixed-shape (B=64, T=8) batches. Returns one mean phrase-token
    /// log-prob per keyword. N>64 would split into multiple calls; for
    /// wake-word use case N is tiny (≤5), so always single chunk.
    private static func forcedDecodeScoresStatic(
        model: MLModel,
        keywordTokens: [(keyword: String, tokenIds: [Int])],
        encoderOutput: MLMultiArray
    ) throws -> WhisperKwsDecodeScores {
        let N = keywordTokens.count
        guard N > 0 else {
            return WhisperKwsDecodeScores(scores: [], inputMs: 0, predictionMs: 0, postprocessMs: 0, totalMs: 0)
        }
        let B = decoderBatch
        var scores: [Float] = []
        scores.reserveCapacity(N)
        var inputMs: Double = 0
        var predictionMs: Double = 0
        var postprocessMs: Double = 0
        var totalMs: Double = 0
        var start = 0
        while start < N {
            let end = min(start + B, N)
            let chunk = Array(keywordTokens[start..<end])
            let decoded = try forcedDecodeScoresChunkStatic(
                encoderOutput: encoderOutput,
                keywordChunk: chunk,
                model: model
            )
            scores.append(contentsOf: decoded.scores)
            inputMs += decoded.inputMs
            predictionMs += decoded.predictionMs
            postprocessMs += decoded.postprocessMs
            totalMs += decoded.totalMs
            start = end
        }
        return WhisperKwsDecodeScores(
            scores: scores,
            inputMs: inputMs,
            predictionMs: predictionMs,
            postprocessMs: postprocessMs,
            totalMs: totalMs
        )
    }

    private static func forcedDecodeScoresChunkStatic(
        encoderOutput: MLMultiArray,
        keywordChunk: [(keyword: String, tokenIds: [Int])],
        model: MLModel
    ) throws -> WhisperKwsDecodeScores {
        let totalStarted = DispatchTime.now()
        let inputStarted = DispatchTime.now()
        let N = keywordChunk.count
        guard N > 0 else {
            return WhisperKwsDecodeScores(scores: [], inputMs: 0, predictionMs: 0, postprocessMs: 0, totalMs: 0)
        }
        let B = Self.decoderBatch
        let T = Self.decoderSeqLen
        let prefixCount = Self.decoderPrefixCount

        // Build input_ids [B, T] Int32 — keyword rows + EOT-padded filler.
        let inputIds = try MLMultiArray(
            shape: [NSNumber(value: B), NSNumber(value: T)],
            dataType: .int32
        )
        let idsPtr = inputIds.dataPointer.assumingMemoryBound(to: Int32.self)
        let idsS0 = inputIds.strides[0].intValue
        let idsS1 = inputIds.strides[1].intValue
        for i in 0..<B {
            if i < N {
                let tokens = keywordChunk[i].tokenIds
                for j in 0..<T {
                    idsPtr[i * idsS0 + j * idsS1] = j < tokens.count ? Int32(tokens[j]) : Self.eotTokenId
                }
            } else {
                for j in 0..<T {
                    idsPtr[i * idsS0 + j * idsS1] = Self.eotTokenId
                }
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "encoder_hidden_states": MLFeatureValue(multiArray: encoderOutput),
        ])
        let inputMs = Self.elapsedMs(since: inputStarted)
        let predictionStarted = DispatchTime.now()
        let output = try model.prediction(from: input)
        let predictionMs = Self.elapsedMs(since: predictionStarted)
        let postStarted = DispatchTime.now()
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw WhisperKwsScorerError.inferenceError("TextDecoderParallel: missing 'logits' output")
        }

        guard logits.shape.count == 3,
              logits.shape[0].intValue == B,
              logits.shape[1].intValue == T,
              logits.shape[2].intValue == Self.vocabSize
        else {
            throw WhisperKwsScorerError.inferenceError(
                "TextDecoderParallel logits unexpected shape \(logits.shape)"
            )
        }
        let logitsPtr = logits.dataPointer.assumingMemoryBound(to: Float16.self)
        let s0 = logits.strides[0].intValue
        let s1 = logits.strides[1].intValue
        let s2 = logits.strides[2].intValue
        let V = Self.vocabSize
        guard s2 == 1 else {
            throw WhisperKwsScorerError.inferenceError(
                "TextDecoderParallel logits vocab stride \(s2) != 1; "
                + "vectorized log-softmax requires a contiguous row"
            )
        }

        // Shared-prefix optimization: all real rows (i < N) have IDENTICAL
        // input_ids[0..prefixCount-1], so the decoder hidden state at
        // position prefixCount-1 is identical across rows, and so are the
        // logits. Compute log_sum_exp ONCE for position 3 (using row 0's
        // data) and reuse for every keyword's first phrase-token score.
        var scores = [Float](repeating: -.infinity, count: N)
        let scoresLock = NSLock()
        let logitsAddr = UInt(bitPattern: logitsPtr)

        let sharedScratch = UnsafeMutablePointer<Float>.allocate(capacity: V)
        defer { sharedScratch.deallocate() }
        let sharedRowBase = 0 * s0 + (prefixCount - 1) * s1
        let sharedLogSumExp = Self.computeLogSumExp(
            rowPtr: logitsPtr + sharedRowBase,
            vocab: V,
            scratch: sharedScratch
        )
        let sharedRowFloats = UnsafeMutablePointer<Float>.allocate(capacity: V)
        defer { sharedRowFloats.deallocate() }
        Self.convertFP16RowToFloat(
            rowPtr: logitsPtr + sharedRowBase, vocab: V, dst: sharedRowFloats
        )
        let sharedRowFloatsAddr = UInt(bitPattern: sharedRowFloats)

        DispatchQueue.concurrentPerform(iterations: N) { i in
            let tokens = keywordChunk[i].tokenIds
            let phraseLen = tokens.count - prefixCount
            guard phraseLen > 0 else { return }
            let logitsP = UnsafePointer<Float16>(bitPattern: logitsAddr)!
            let sharedRow = UnsafePointer<Float>(bitPattern: sharedRowFloatsAddr)!
            var sum: Float = 0
            for k in 0..<phraseLen {
                let pos = prefixCount - 1 + k
                let nextToken = tokens[prefixCount + k]
                if k == 0 {
                    sum += sharedRow[nextToken] - sharedLogSumExp
                } else {
                    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: V)
                    defer { scratch.deallocate() }
                    let rowBase = i * s0 + pos * s1
                    sum += Self.logSoftmaxAt(
                        rowPtr: logitsP + rowBase,
                        vocab: V,
                        tokenId: nextToken,
                        scratch: scratch
                    )
                }
            }
            let s = sum / Float(phraseLen)
            scoresLock.lock()
            scores[i] = s
            scoresLock.unlock()
        }
        return WhisperKwsDecodeScores(
            scores: scores,
            inputMs: inputMs,
            predictionMs: predictionMs,
            postprocessMs: Self.elapsedMs(since: postStarted),
            totalMs: Self.elapsedMs(since: totalStarted)
        )
    }

    /// log-sum-exp of a 51865-wide row of fp16 logits. Mutates `scratch`.
    private static func computeLogSumExp(
        rowPtr: UnsafePointer<Float16>,
        vocab: Int,
        scratch: UnsafeMutablePointer<Float>
    ) -> Float {
        var srcImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: rowPtr),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * MemoryLayout<Float16>.size
        )
        var dstImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(scratch),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * MemoryLayout<Float>.size
        )
        vImageConvert_Planar16FtoPlanarF(&srcImage, &dstImage, 0)
        var maxLogit: Float = 0
        vDSP_maxv(scratch, 1, &maxLogit, vDSP_Length(vocab))
        var negMax = -maxLogit
        vDSP_vsadd(scratch, 1, &negMax, scratch, 1, vDSP_Length(vocab))
        var n = Int32(vocab)
        vvexpf(scratch, scratch, &n)
        var sumExp: Float = 0
        vDSP_sve(scratch, 1, &sumExp, vDSP_Length(vocab))
        return maxLogit + Foundation.log(sumExp)
    }

    private static func convertFP16RowToFloat(
        rowPtr: UnsafePointer<Float16>,
        vocab: Int,
        dst: UnsafeMutablePointer<Float>
    ) {
        var srcImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: rowPtr),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * MemoryLayout<Float16>.size
        )
        var dstImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(dst),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * MemoryLayout<Float>.size
        )
        vImageConvert_Planar16FtoPlanarF(&srcImage, &dstImage, 0)
    }

    /// Numerically-stable log-softmax of a contiguous (stride==1) row of
    /// `vocab` Float16 logits at `rowPtr`, returning the log-prob at
    /// `tokenId`. `scratch` is a Float32 buffer of length ≥ vocab.
    private static func logSoftmaxAt(
        rowPtr: UnsafePointer<Float16>,
        vocab: Int,
        tokenId: Int,
        scratch: UnsafeMutablePointer<Float>
    ) -> Float {
        var srcImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: rowPtr),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * MemoryLayout<Float16>.size
        )
        var dstImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(scratch),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * MemoryLayout<Float>.size
        )
        vImageConvert_Planar16FtoPlanarF(&srcImage, &dstImage, 0)

        var maxLogit: Float = 0
        vDSP_maxv(scratch, 1, &maxLogit, vDSP_Length(vocab))
        var negMax = -maxLogit
        vDSP_vsadd(scratch, 1, &negMax, scratch, 1, vDSP_Length(vocab))
        var n = Int32(vocab)
        vvexpf(scratch, scratch, &n)
        var sumExp: Float = 0
        vDSP_sve(scratch, 1, &sumExp, vDSP_Length(vocab))
        let logSumExp = maxLogit + Foundation.log(sumExp)

        let logit = Float(rowPtr[tokenId])
        return logit - logSumExp
    }

    // MARK: - Bundle helpers

    private static func loadModel(
        named name: String,
        computeUnits: MLComputeUnits
    ) throws -> MLModel {
        let url = try modelURL(named: name)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.allowLowPrecisionAccumulationOnGPU = true
        return try MLModel(contentsOf: url, configuration: config)
    }

    private static func modelURL(named name: String) throws -> URL {
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = Bundle.main.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "WhisperKWS"
            ) {
                return url
            }
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        throw WhisperKwsScorerError.modelFilesNotFound("\(name).mlmodelc/.mlpackage")
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private static func ms(_ value: Double) -> String {
        String(format: "%.1fms", value)
    }

    private static func score(_ value: Float) -> String {
        String(format: "%.2f", value)
    }
}
#endif
