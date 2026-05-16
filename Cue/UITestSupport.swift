#if DEBUG
import Foundation

/// Launch-argument hooks used only by `CueUITests` to boot the app directly
/// into a target screen. Stripped from Release builds.
enum UITestFlag {
    /// Bypass auth so the app goes straight past `AuthView` into `ContentView`.
    static var bypassAuth: Bool {
        ProcessInfo.processInfo.arguments.contains("-CueUITestBypassAuth")
    }

    /// Open the full `PlayerView` on launch with the sample transcript,
    /// without going through `loadLive` (no `state.live`, no audio). Useful
    /// for layout-only checks.
    static var openSamplePlayer: Bool {
        ProcessInfo.processInfo.arguments.contains("-CueUITestOpenSamplePlayer")
    }

    /// Open the full `PlayerView` on launch via a synthetic `loadLive` call —
    /// `state.live` is set, then `state.playerOpen` is animated open in the
    /// same tick. Mirrors the exact state sequence that fires when the user
    /// taps a library row. Skips the audio side-effects (audioUrl is empty).
    static var openSampleLive: Bool {
        ProcessInfo.processInfo.arguments.contains("-CueUITestOpenSampleLive")
    }

    /// Skip the app's eager microphone permission request so UI tests can
    /// measure player layout without a system alert covering the screen.
    static var skipMicPermission: Bool {
        ProcessInfo.processInfo.arguments.contains("-CueUITestSkipMicPermission")
    }
}

/// Builds a `LiveEpisode` from the canned `SampleData` transcript so the
/// player can be loaded through the real `loadLive` flow without any network
/// I/O. `episode.audioUrl` is empty on purpose — `loadLive` skips the audio
/// load when `URL(string:)` returns nil, so no AVPlayer instance is created.
///
/// `repeats` lets the test inflate the transcript to a realistic podcast
/// scale (e.g. 60 → ~720 sentences / ~12k words) so we exercise LazyVStack's
/// lazy-loading path, not the trivial 12-item version.
@MainActor
enum SampleLiveEpisodeFactory {
    static func make(repeats: Int = 1) -> LiveEpisode {
        let baseWords = SampleData.words
        let baseSentences = SampleData.sentences
        let baseDuration = SampleData.totalDuration

        var allWords: [TranscribeWord] = []
        var allSegments: [TranscribeSegment] = []
        for r in 0..<max(1, repeats) {
            let offset = Double(r) * baseDuration
            for w in baseWords {
                allWords.append(TranscribeWord(
                    text: w.text,
                    startMs: Int((w.start + offset) * 1000),
                    endMs: Int((w.end + offset) * 1000)
                ))
            }
            for s in baseSentences {
                allSegments.append(TranscribeSegment(
                    speaker: s.speaker,
                    startMs: Int((s.start + offset) * 1000),
                    endMs: Int((s.end + offset) * 1000),
                    text: s.words.map(\.text).joined(separator: " ")
                ))
            }
        }
        let transcript = TranscribeResponse(
            provider: "ui-test",
            text: allSegments.map(\.text).joined(separator: " "),
            words: allWords,
            segments: allSegments,
            cached: true,
            durationSeconds: baseDuration * Double(max(1, repeats))
        )
        let show = ResolvedShow(
            title: "Deep Field",
            author: nil,
            feedUrl: "ui-test://deep-field",
            artworkUrl: nil
        )
        let episode = ResolvedEpisode(
            title: "Galaxies that shouldn't exist",
            audioUrl: "", // empty → loadLive skips the audio.load() call
            durationSeconds: transcript.durationSeconds,
            pubDate: nil,
            guid: "ui-test-sample",
            description: nil,
            artworkUrl: nil
        )
        return LiveEpisode(show: show, episode: episode, transcript: transcript)
    }
}
#endif
