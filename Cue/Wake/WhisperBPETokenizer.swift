#if os(iOS)
//
//  WhisperBPETokenizer.swift
//  Cue
//
//  Byte-level GPT-2 BPE tokenizer for Whisper. Ported verbatim from
//  onit-beacon (macos/Onit/Transcription/CustomDictionary/WhisperBPETokenizer.swift).
//
//  Loads vocab.json + merges.txt from Cue/Resources/WhisperKWS/. Bytes (0–255)
//  are first mapped through the canonical GPT-2 `byte_to_unicode` table, then
//  the resulting unicode-character sequence is BPE-merged using `merges.txt`
//  priorities, then each final piece is looked up in `vocab.json` to produce
//  token IDs.
//
//  Intentionally minimal: no GPT-2 pre-tokenization regex. Single-word
//  wake-phrase inputs ("orbit", "orbital", "orbits") with a forced leading
//  space match how Whisper forced-decode of mid-sentence keywords behaves.
//

import Foundation
import os.log

/// Byte-level BPE tokenizer for OpenAI Whisper (multilingual variant, 50,258 vocab).
/// Loads `vocab.json` + `merges.txt` from the bundle on first use and caches them
/// inside the actor for the lifetime of the process.
actor WhisperBPETokenizer {
    static let shared = WhisperBPETokenizer()

    /// Multilingual decoder prefix: `<|startoftranscript|><|en|><|transcribe|><|notimestamps|>`.
    /// Hardcoded — matches HuggingFace `openai/whisper-base` `added_tokens.json`.
    static let decoderPrefix: [Int] = [50258, 50259, 50359, 50363]

    private let log = Logger(subsystem: "app.cue", category: "WhisperBPETokenizer")

    /// Hashable pair of subword strings, indexed in `mergeRank`.
    private struct MergePair: Hashable {
        let first: String
        let second: String
    }

    /// Lazy state — populated on first `encode` call.
    private var vocab: [String: Int]?
    private var mergeRank: [MergePair: Int]?
    /// `byte (0-255) → 1-character String` mapping (the GPT-2 byte_to_unicode table).
    private var byteToUnicode: [Character]?

    enum WhisperBPEError: LocalizedError {
        case resourceNotFound(String)
        case invalidVocab(String)
        case invalidMerges(String)
        case unknownToken(String)

        var errorDescription: String? {
            switch self {
            case .resourceNotFound(let n): return "WhisperKWS resource not found in bundle: \(n)"
            case .invalidVocab(let m):     return "Invalid vocab.json: \(m)"
            case .invalidMerges(let m):    return "Invalid merges.txt: \(m)"
            case .unknownToken(let t):     return "BPE produced unknown subword piece: '\(t)'"
            }
        }
    }

    // MARK: - Public API

    /// Encode `text` to Whisper token IDs.
    ///
    /// - Parameter withDecoderPrefix: If true, prepend the multilingual decoder prefix
    ///   (`<|startoftranscript|><|en|><|transcribe|><|notimestamps|>`).
    ///
    /// The body text is always encoded with a synthetic leading space to match how
    /// forced-decode of mid-sentence keywords behaves — e.g. `encode("orbit")` of
    /// just the body produces `[BPE pieces for " orb" + "it"]`.
    func encode(_ text: String, withDecoderPrefix: Bool = true) throws -> [Int] {
        try ensureLoaded()
        let bodyIds = try bpeEncodeBody(text)
        return withDecoderPrefix ? Self.decoderPrefix + bodyIds : bodyIds
    }

    // MARK: - Loading

    private func ensureLoaded() throws {
        if vocab != nil, mergeRank != nil, byteToUnicode != nil { return }

        guard let vocabPath = Self.bundlePath("vocab", ext: "json") else {
            throw WhisperBPEError.resourceNotFound("vocab.json")
        }
        guard let mergesPath = Self.bundlePath("merges", ext: "txt") else {
            throw WhisperBPEError.resourceNotFound("merges.txt")
        }

        // vocab.json is `[String: Int]` — no nesting.
        let vocabData = try Data(contentsOf: URL(fileURLWithPath: vocabPath))
        guard let vocabDict = try JSONSerialization.jsonObject(with: vocabData) as? [String: Int] else {
            throw WhisperBPEError.invalidVocab("root is not [String: Int]")
        }
        self.vocab = vocabDict

        // merges.txt: first line is `#version: 0.2`; each subsequent non-empty line
        // is `<a> <b>` where rank = line index (excluding the version line).
        let mergesText = try String(contentsOfFile: mergesPath, encoding: .utf8)
        var ranks: [MergePair: Int] = [:]
        var rank = 0
        for (idx, rawLine) in mergesText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = String(rawLine)
            if line.isEmpty { continue }
            if idx == 0, line.hasPrefix("#version") { continue }
            // Use first space split; merge tokens themselves never contain spaces
            // because byte 0x20 maps to U+0120 (Ġ) before any merging happens.
            guard let space = line.firstIndex(of: " ") else {
                throw WhisperBPEError.invalidMerges("missing space in merge line: '\(line)'")
            }
            let a = String(line[line.startIndex..<space])
            let b = String(line[line.index(after: space)...])
            let pair = MergePair(first: a, second: b)
            if ranks[pair] == nil {
                ranks[pair] = rank
            }
            rank += 1
        }
        self.mergeRank = ranks

        // Build the GPT-2 byte_to_unicode table.
        self.byteToUnicode = Self.buildByteToUnicode()

        log.info("WhisperBPETokenizer loaded: vocab=\(vocabDict.count, privacy: .public), merges=\(ranks.count, privacy: .public)")
    }

    // MARK: - byte_to_unicode

    /// Canonical GPT-2 `byte_to_unicode` table.
    ///
    /// The set of "printable" bytes (`!`–`~`, `¡`–`¬`, `®`–`ÿ`) maps to itself.
    /// The remaining 68 bytes (control chars, space, soft hyphen, `\xad`, etc.) map
    /// to U+0100, U+0101, … in order — giving a reversible byte ↔ printable-character
    /// bijection that BPE can operate on safely.
    private static func buildByteToUnicode() -> [Character] {
        var bs: [Int] = []
        bs.append(contentsOf: 0x21...0x7E)   // '!' through '~'
        bs.append(contentsOf: 0xA1...0xAC)   // '¡' through '¬'
        bs.append(contentsOf: 0xAE...0xFF)   // '®' through 'ÿ'

        var cs = bs  // each printable byte maps to itself
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }

        var table: [Character] = Array(repeating: "\0", count: 256)
        for i in 0..<bs.count {
            guard let scalar = Unicode.Scalar(cs[i]) else {
                preconditionFailure("byte_to_unicode: unable to build scalar for \(cs[i])")
            }
            table[bs[i]] = Character(scalar)
        }
        return table
    }

    // MARK: - BPE

    /// Encode a single body string to token IDs. Always prepends a leading space first.
    private func bpeEncodeBody(_ text: String) throws -> [Int] {
        guard let vocab = vocab, let mergeRank = mergeRank, let b2u = byteToUnicode else {
            throw WhisperBPEError.resourceNotFound("tokenizer not loaded")
        }
        if text.isEmpty {
            return []
        }

        // Convention: prepend a synthetic leading space so we tokenize as if mid-sentence.
        let withLeadingSpace = " " + text

        // 1. UTF-8 byte representation.
        let bytes: [UInt8] = Array(withLeadingSpace.utf8)

        // 2. Map each byte through the byte_to_unicode table → 1-char strings.
        var pieces: [String] = []
        pieces.reserveCapacity(bytes.count)
        for b in bytes {
            pieces.append(String(b2u[Int(b)]))
        }

        if pieces.isEmpty { return [] }
        if pieces.count == 1 {
            return [try lookup(pieces[0], vocab: vocab)]
        }

        // 3. BPE merge loop — repeatedly merge the highest-ranked adjacent pair.
        while true {
            var bestRank: Int?
            var bestPair: MergePair?

            for i in 0..<(pieces.count - 1) {
                let pair = MergePair(first: pieces[i], second: pieces[i + 1])
                guard let r = mergeRank[pair] else { continue }
                if bestRank.map({ r < $0 }) ?? true {
                    bestRank = r
                    bestPair = pair
                }
            }

            guard let pair = bestPair else { break }

            var merged: [String] = []
            merged.reserveCapacity(pieces.count)
            var i = 0
            while i < pieces.count {
                if i < pieces.count - 1, pieces[i] == pair.first, pieces[i + 1] == pair.second {
                    merged.append(pair.first + pair.second)
                    i += 2
                } else {
                    merged.append(pieces[i])
                    i += 1
                }
            }
            if merged.count == pieces.count { break }  // defensive
            pieces = merged
            if pieces.count < 2 { break }
        }

        // 4. Vocab lookup. Whisper's byte-level BPE is exhaustive over all 256 bytes,
        //    so unknown subwords here indicate a real bug — surface as a thrown error.
        return try pieces.map { try lookup($0, vocab: vocab) }
    }

    private func lookup(_ token: String, vocab: [String: Int]) throws -> Int {
        guard let id = vocab[token] else {
            throw WhisperBPEError.unknownToken(token)
        }
        return id
    }

    // MARK: - Bundle helpers

    private static func bundlePath(_ filename: String, ext: String) -> String? {
        // Try the WhisperKWS subdirectory first (matches the bundle layout
        // when synchronized root groups preserve folder structure), then
        // fall back to the flat bundle (some Xcode versions flatten).
        if let p = Bundle.main.path(forResource: filename, ofType: ext, inDirectory: "WhisperKWS") {
            return p
        }
        return Bundle.main.path(forResource: filename, ofType: ext)
    }
}
#endif
