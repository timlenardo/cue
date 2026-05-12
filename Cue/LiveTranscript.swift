import Foundation

/// Bridges a Whisper response into the player's TranscriptSentence/Word types.
extension LiveEpisode {

    /// Word-level timeline in seconds.
    var liveWords: [TranscriptWord] {
        let segments = transcript.segments
        let rawWords = transcript.words

        // Find which segment each word lives in (by overlap on the start mark).
        let starts = segments.map { $0.startMs }

        var out: [TranscriptWord] = []
        out.reserveCapacity(rawWords.count)
        for (i, w) in rawWords.enumerated() {
            let segIdx = lastIndex(at: w.startMs, in: starts)
            let speaker = segIdx >= 0 ? segments[segIdx].speaker : "?"
            out.append(TranscriptWord(
                text: w.text,
                start: Double(w.startMs) / 1000.0,
                end: Double(w.endMs) / 1000.0,
                sentenceIdx: max(0, segIdx),
                speaker: speaker,
                globalIdx: i
            ))
        }
        return out
    }

    /// Sentence-level timeline (1 sentence = 1 Whisper segment).
    var liveSentences: [TranscriptSentence] {
        let words = liveWords
        var bySentence: [Int: [TranscriptWord]] = [:]
        for w in words { bySentence[w.sentenceIdx, default: []].append(w) }

        return transcript.segments.enumerated().map { idx, seg -> TranscriptSentence in
            let ws = bySentence[idx] ?? []
            return TranscriptSentence(
                id: idx,
                speaker: seg.speaker,
                start: Double(seg.startMs) / 1000.0,
                end: Double(seg.endMs) / 1000.0,
                words: ws
            )
        }
    }

    /// Player chapters — Whisper doesn't emit chapters, so we synthesize a single
    /// "Episode" marker so the chapter label always has something to display.
    var liveChapters: [Chapter] {
        [Chapter(t: 0, title: episode.title)]
    }

    private func lastIndex(at ms: Int, in starts: [Int]) -> Int {
        // Largest index i such that starts[i] <= ms. -1 if before all.
        var lo = 0, hi = starts.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= ms { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }
}
