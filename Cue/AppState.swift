import SwiftUI
import Combine

enum Tab: String { case listen, library, notes }

enum LoadPhase: Equatable {
    case idle
    case resolving
    /// `progress` is 0..1 when known, nil before chunks are reported.
    case transcribing(stage: String, progress: Double?, chunkCount: Int?)
    case error(String)
}

struct LiveEpisode {
    let show: ResolvedShow
    let episode: ResolvedEpisode
    let transcript: TranscribeResponse
}

@MainActor
final class AppState: ObservableObject {
    @Published var tab: Tab = .listen
    @Published var playerOpen: Bool = false
    @Published var voiceOpen: Bool = false

    @Published var currentTime: Double = 0
    @Published var playing: Bool = false
    @Published var speedIdx: Int = 0
    @Published var qaIdx: Int = 0

    @Published var paletteName: PaletteName = .paper

    @Published var loadPhase: LoadPhase = .idle
    @Published var live: LiveEpisode?

    let audio = AudioPlayer()
    private var audioSubs: Set<AnyCancellable> = []

    var palette: Palette { paletteName.palette }
    var speed: Double { Speeds.values[speedIdx] }

    /// Effective duration — AVPlayer's duration when live, else the canned sample transcript.
    var totalDuration: Double {
        if let live {
            if audio.duration > 0 { return audio.duration }
            if let d = live.episode.durationSeconds { return d }
            if let d = live.transcript.durationSeconds { return d }
        }
        return SampleData.totalDuration
    }

    // MARK: - Init

    private var simulatedTimer: AnyCancellable?
    private var lastSimulatedTick: Date?

    init() {
        startSimulatedTimer()

        // Mirror AudioPlayer's time + playing state into AppState's @Published
        // properties so transcript/progress views update reactively.
        audio.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                guard let self else { return }
                if self.live != nil { self.currentTime = t }
            }
            .store(in: &audioSubs)

        audio.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p in
                guard let self else { return }
                if self.live != nil { self.playing = p }
            }
            .store(in: &audioSubs)
    }

    private func startSimulatedTimer() {
        simulatedTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.simulatedTick() }
    }

    /// Advances time only for the canned sample (no `live`). AVPlayer drives time when live.
    private func simulatedTick() {
        guard live == nil else { return }
        guard playing, !voiceOpen else {
            lastSimulatedTick = nil
            return
        }
        let now = Date()
        let dt = lastSimulatedTick.map { now.timeIntervalSince($0) } ?? (1.0 / 30.0)
        lastSimulatedTick = now
        let next = currentTime + dt * speed
        if next >= totalDuration {
            currentTime = totalDuration
            playing = false
        } else {
            currentTime = next
        }
    }

    // MARK: - Intents

    func togglePlay() {
        if live != nil {
            if audio.isPlaying { audio.pause() } else { audio.play(); audio.setRate(Float(speed)) }
        } else {
            playing.toggle()
        }
    }

    func skipBack15() {
        if live != nil { audio.seek(to: max(0, audio.currentTime - 15)) }
        else { currentTime = max(0, currentTime - 15) }
    }

    func skipFwd15() {
        if live != nil { audio.seek(to: min(totalDuration, audio.currentTime + 15)) }
        else { currentTime = min(totalDuration, currentTime + 15) }
    }

    func cycleSpeed() {
        speedIdx = (speedIdx + 1) % Speeds.values.count
        if live != nil, audio.isPlaying { audio.setRate(Float(speed)) }
    }

    func openPlayer()     { withAnimation(.easeOut(duration: 0.28)) { playerOpen = true } }
    func minimizePlayer() { withAnimation(.easeOut(duration: 0.28)) { playerOpen = false } }

    func openMic() {
        withAnimation(.easeOut(duration: 0.32)) { voiceOpen = true }
        // Pause podcast while the agent is open.
        if live != nil { audio.pause() }
    }
    func resumeAfterVoice() {
        withAnimation(.easeOut(duration: 0.25)) { voiceOpen = false }
        qaIdx += 1
        if live != nil { audio.play(); audio.setRate(Float(speed)) }
        else { playing = true }
    }
    func askAgain() {
        withAnimation(.easeOut(duration: 0.2)) { voiceOpen = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeOut(duration: 0.3)) { self.voiceOpen = true }
        }
    }

    func seek(_ t: Double) {
        let clamped = max(0, min(totalDuration, t))
        if live != nil { audio.seek(to: clamped) }
        else { currentTime = clamped }
    }

    /// Called by EntryView after a successful resolve+transcribe.
    func loadLive(_ live: LiveEpisode) {
        self.live = live
        self.currentTime = 0
        self.qaIdx = 0
        if let url = URL(string: live.episode.audioUrl) {
            audio.load(url: url)
            audio.play()
            audio.setRate(Float(speed))
        }
        openPlayer()
    }

    // MARK: - Player accessors (live vs canned)

    var episodeTitle: String {
        live?.episode.title ?? SampleData.episodeMeta.title
    }

    var episodeShowName: String {
        live?.show.title ?? SampleData.episodeMeta.show
    }

    var episodeEyebrow: String {
        if live != nil { return episodeShowName.uppercased() }
        let meta = SampleData.episodeMeta
        return "EP \(meta.number) · \(meta.show)".uppercased()
    }

    var transcriptSentences: [TranscriptSentence] {
        live?.liveSentences ?? SampleData.sentences
    }

    var transcriptWords: [TranscriptWord] {
        live?.liveWords ?? SampleData.words
    }

    var chapters: [Chapter] {
        live?.liveChapters ?? SampleData.chapters
    }

    func currentChapter() -> Chapter {
        let cs = chapters
        var current = cs.first ?? Chapter(t: 0, title: episodeTitle)
        for c in cs where currentTime >= c.t { current = c }
        return current
    }
}
