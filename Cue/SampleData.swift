import Foundation
import SwiftUI

enum SampleData {

    // MARK: - Shows

    static let shows: [String: Show] = [
        "deep":   Show(key: "deep",   name: "Deep Field",          mono: "DF", color: Color(hex: "1F2A3A")),
        "daily":  Show(key: "daily",  name: "The Daily",           mono: "TD", color: Color(hex: "7A2A1F")),
        "invis":  Show(key: "invis",  name: "99% Invisible",       mono: "99", color: Color(hex: "C9A24A")),
        "hard":   Show(key: "hard",   name: "Hard Fork",           mono: "HF", color: Color(hex: "2A4A2E")),
        "ezra":   Show(key: "ezra",   name: "The Ezra Klein Show", mono: "EK", color: Color(hex: "4A3060")),
        "search": Show(key: "search", name: "Search Engine",       mono: "SE", color: Color(hex: "B5612A")),
    ]

    static func show(_ key: String) -> Show {
        shows[key] ?? Show(key: key, name: key, mono: "?", color: .gray)
    }

    // MARK: - Library

    static let nowPlaying = Episode(
        showKey: "deep",
        title: "Galaxies that shouldn't exist",
        duration: 47 * 60 + 12,
        progress: 0.034,
        dateLabel: "Today"
    )

    static let queue: [Episode] = [
        .init(showKey: "hard",  title: "The agents are here, for real this time", duration: 58 * 60 + 10, progress: 0,    dateLabel: "May 9"),
        .init(showKey: "ezra",  title: "What we get wrong about cities",          duration: 71 * 60 + 5,  progress: 0,    dateLabel: "May 7"),
        .init(showKey: "invis", title: "The eighty-million-dollar pothole",       duration: 32 * 60 + 44, progress: 0,    dateLabel: "May 6"),
    ]

    static let history: [Episode] = [
        .init(showKey: "daily",  title: "A judge, a tariff, and a deadline",  duration: 28 * 60 + 30, progress: 0.62, dateLabel: "Yesterday"),
        .init(showKey: "search", title: "Why is my grocery bill so weird?",   duration: 41 * 60 + 2,  progress: 1,    dateLabel: "Tue"),
        .init(showKey: "invis",  title: "The shape of a freeway sign",        duration: 36 * 60 + 18, progress: 1,    dateLabel: "Tue"),
        .init(showKey: "ezra",   title: "A conversation about loneliness",    duration: 64 * 60 + 44, progress: 0.21, dateLabel: "Mon"),
        .init(showKey: "hard",   title: "OpenAI vs. everyone, again",         duration: 49 * 60 + 12, progress: 1,    dateLabel: "May 2"),
    ]

    // MARK: - Notes

    static let notes: [NoteGroup] = [
        NoteGroup(
            showKey: "deep",
            episode: "Galaxies that shouldn't exist",
            when: "Today",
            items: [
                NoteItem(kind: .ask,  timestamp: "00:48", body: "Why does the universe expanding pull light into infrared?"),
                NoteItem(kind: .clip, timestamp: "01:12", body: "\u{201C}Light from the most distant galaxies has been traveling for over thirteen billion years to reach the mirror.\u{201D}"),
            ]
        ),
        NoteGroup(
            showKey: "ezra",
            episode: "A conversation about loneliness",
            when: "Monday",
            items: [
                NoteItem(kind: .ask,  timestamp: "14:22", body: "What did Putnam mean by \u{201C}social capital\u{201D} exactly?"),
                NoteItem(kind: .ask,  timestamp: "32:09", body: "Is this loneliness epidemic actually new, or did we just start measuring?"),
                NoteItem(kind: .clip, timestamp: "47:51", body: "\u{201C}The point isn\u{2019}t to manufacture community. The point is to stop demolishing it.\u{201D}"),
            ]
        ),
        NoteGroup(
            showKey: "search",
            episode: "Why is my grocery bill so weird?",
            when: "Tuesday",
            items: [
                NoteItem(kind: .ask, timestamp: "08:14", body: "How is shrinkflation different from regular inflation?"),
            ]
        ),
    ]

    // MARK: - Transcript

    private static let rawTranscript: [(String, String)] = [
        ("Maya",  "Welcome back to Deep Field. I'm Maya Chen, and today we're going to the edge of time."),
        ("Maya",  "The James Webb Space Telescope has been operating for almost four years now, and the images it sends back keep rewriting our cosmology textbooks."),
        ("Maya",  "In every batch of data, we are finding galaxies that, according to our models, should not exist yet."),
        ("Maya",  "They are too bright, too big, and too well-formed for the era we are looking at."),
        ("Maya",  "To understand why that is strange, you have to remember what Webb is actually seeing."),
        ("Maya",  "It is not pointed at the sky like a normal camera. It is pointed at the past."),
        ("Maya",  "Light from the most distant galaxies has been traveling for over thirteen billion years to reach the mirror."),
        ("Maya",  "And along the way, the universe itself has stretched. The wavelength of that light has been pulled into the infrared."),
        ("Maya",  "That is why Webb's instruments are tuned the way they are. It is built specifically to read this redshifted, ancient light."),
        ("Maya",  "Joining me to unpack what we are learning is Dr. Idris Okafor, an observational cosmologist at Caltech. Idris, welcome to the show."),
        ("Idris", "Thanks for having me, Maya. It's a strange and wonderful time to be doing this work."),
        ("Maya",  "Let's start there. From your seat, what is the single most surprising thing Webb has shown us?"),
    ]

    /// Build word-level timeline from raw transcript at ~155 WPM with realistic pauses.
    /// Mirrors transcript.jsx exactly.
    static let (words, sentences, totalDuration): ([TranscriptWord], [TranscriptSentence], Double) = {
        let wpm: Double = 155
        let secPerWord: Double = 60 / wpm
        let sentencePause: Double = 0.35
        let speakerPause: Double = 0.9

        var words: [TranscriptWord] = []
        var t: Double = 0
        var lastSpeaker: String? = nil

        for (si, line) in rawTranscript.enumerated() {
            let (speaker, text) = line
            if let last = lastSpeaker, last != speaker {
                t += speakerPause
            }
            lastSpeaker = speaker
            let tokens = text.split(separator: " ").map(String.init)
            for (wi, tok) in tokens.enumerated() {
                let ends = tok.last.map { ".?!".contains($0) } ?? false
                let lengthBias = min(1.4, Double(tok.count) / 6.0)
                let dur = secPerWord * (0.7 + lengthBias)
                words.append(TranscriptWord(
                    text: tok,
                    start: t,
                    end: t + dur,
                    sentenceIdx: si,
                    speaker: speaker,
                    globalIdx: words.count
                ))
                t += dur
                if ends && wi < tokens.count - 1 {
                    t += sentencePause
                }
            }
            t += sentencePause
        }

        // Group words by sentence.
        var sentenceMap: [Int: (speaker: String, start: Double, end: Double, words: [TranscriptWord])] = [:]
        for w in words {
            if var s = sentenceMap[w.sentenceIdx] {
                s.end = w.end
                s.words.append(w)
                sentenceMap[w.sentenceIdx] = s
            } else {
                sentenceMap[w.sentenceIdx] = (w.speaker, w.start, w.end, [w])
            }
        }
        let sentences = sentenceMap.keys.sorted().map { idx -> TranscriptSentence in
            let s = sentenceMap[idx]!
            return TranscriptSentence(id: idx, speaker: s.speaker, start: s.start, end: s.end, words: s.words)
        }

        return (words, sentences, t)
    }()

    // MARK: - Chapters / Episode

    static let chapters: [Chapter] = [
        Chapter(t: 0,  title: "Cold open"),
        Chapter(t: 16, title: "Why galaxies \u{201C}shouldn\u{2019}t exist\u{201D}"),
        Chapter(t: 38, title: "Webb sees the past, in infrared"),
        Chapter(t: 72, title: "Guest: Dr. Idris Okafor"),
    ]

    static var episodeMeta: EpisodeMeta {
        EpisodeMeta(
            show: "Deep Field",
            number: 47,
            title: "Galaxies that shouldn't exist",
            guest: "Dr. Idris Okafor, Caltech",
            date: "May 8, 2026",
            fullDuration: 47 * 60 + 12,
            transcriptDuration: totalDuration
        )
    }

    static func chapter(at time: Double) -> Chapter {
        var current = chapters[0]
        for c in chapters where time >= c.t { current = c }
        return current
    }

    // MARK: - Sample voice-agent Q&A

    static let sampleQA: [SampleQA] = [
        SampleQA(
            q: "Wait \u{2014} why does the universe expanding pull light into infrared?",
            a: [
                "Great question. When light travels through space that itself is stretching, the waves get stretched along with it.",
                "Visible light has very short wavelengths. When you stretch those waves enough, they slide down into the infrared part of the spectrum \u{2014} same light, just longer waves.",
                "That's why a regular optical telescope would see almost nothing from these very old galaxies. Webb sees them because Webb sees in infrared.",
            ]
        ),
        SampleQA(
            q: "How is this different from what Hubble can see?",
            a: [
                "Hubble is primarily an optical and ultraviolet telescope, so it sees the universe roughly the way human eyes would.",
                "Webb is built around a much larger mirror, and its instruments are tuned for infrared. That combination lets it pick up faint, redshifted light from galaxies that formed in the first few hundred million years after the Big Bang.",
            ]
        ),
        SampleQA(
            q: "What do you mean by 'redshifted'?",
            a: [
                "Redshift is the term for that stretching effect. The further away a galaxy is, the more its light has been stretched toward red \u{2014} and beyond, into infrared.",
                "Astronomers actually use the amount of redshift to estimate how far back in time they're seeing.",
            ]
        ),
    ]
}
