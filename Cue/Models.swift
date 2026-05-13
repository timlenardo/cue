import Foundation
import SwiftUI

struct Show: Identifiable, Equatable {
    let key: String
    let name: String
    let mono: String
    let color: Color
    var id: String { key }
}

struct Episode: Identifiable, Equatable {
    let id = UUID()
    let showKey: String
    let title: String
    let duration: Double   // seconds
    let progress: Double   // 0..1
    let dateLabel: String
}

struct TranscriptWord: Equatable {
    let text: String
    let start: Double
    let end: Double
    let sentenceIdx: Int
    let speaker: String
    let globalIdx: Int
}

struct TranscriptSentence: Identifiable, Equatable {
    let id: Int
    let speaker: String
    let start: Double
    let end: Double
    let words: [TranscriptWord]
    /// Pre-computed " "-joined word text. Lets SentenceBlock render inactive
    /// sentences as plain `Text` without re-concatenating words on every
    /// `currentTime` tick.
    let plainText: String

    init(id: Int, speaker: String, start: Double, end: Double, words: [TranscriptWord]) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.words = words
        self.plainText = words.map(\.text).joined(separator: " ")
    }
}

struct Chapter: Identifiable, Equatable {
    let t: Double
    let title: String
    var id: Double { t }
}

struct EpisodeMeta: Equatable {
    let show: String
    let number: Int
    let title: String
    let guest: String
    let date: String
    let fullDuration: Double
    let transcriptDuration: Double
}

// MARK: - Formatting helpers

enum Format {
    /// "5:09" mm:ss for player progress
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// "37 min" or "1h 11m" — shown in library rows
    static func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return "\(h)h \(r)m"
    }
}
