import SwiftUI
import Combine
import AVFAudio

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
    /// Server-side episode id (from /v1/library upsert response). Used to
    /// scope progress PATCHes. Nil if the live playback isn't yet linked to
    /// a library item (e.g. mid-pipeline before upsert finishes).
    var serverEpisodeId: Int? = nil
}

@MainActor
final class AppState: ObservableObject {
    @Published var tab: Tab = .listen
    @Published var playerOpen: Bool = false
    @Published var voiceOpen: Bool = false

    @Published var currentTime: Double = 0
    @Published var playing: Bool = false
    @Published var speedIdx: Int = AppState.loadSpeedIdx() {
        didSet { AppState.saveSpeedIdx(speedIdx) }
    }
    @Published var qaIdx: Int = 0

    private static let speedIdxKey = "cue.speedIdx"

    private static func loadSpeedIdx() -> Int {
        let raw = UserDefaults.standard.integer(forKey: speedIdxKey)
        guard raw >= 0, raw < Speeds.values.count else { return 0 }
        return raw
    }

    private static func saveSpeedIdx(_ idx: Int) {
        UserDefaults.standard.set(idx, forKey: speedIdxKey)
    }

    @Published var paletteName: PaletteName = .paper

    @Published var loadPhase: LoadPhase = .idle
    @Published var live: LiveEpisode?

    @Published var library: [LibraryItem] = []
    @Published var libraryLoading: Bool = false

    let audio = AudioPlayer()
    private var audioSubs: Set<AnyCancellable> = []
    private var progressSyncTimer: AnyCancellable?
    private var lastSyncedPosition: Double = -1
    private var lastSyncAt: Date?

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
        startProgressSyncTimer()
        NowPlayingCenter.shared.attach(self)

        #if DEBUG
        // Diagnostic: log a single line every ~2s confirming the mic tap is
        // delivering buffers. Remove once the real wake-word listener is in.
        let diag = MicCaptureDiag()
        MicCapture.shared.addBufferHandler { buffer, _ in
            diag.tick(frames: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate)
        }
        #endif

        // Mirror AudioPlayer's time + playing state into AppState's @Published
        // properties so transcript/progress views update reactively.
        audio.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                guard let self else { return }
                if self.live != nil {
                    self.currentTime = t
                    // Throttle Now-Playing updates to ~1Hz to keep CPU low.
                    if Int(t) != self.lastNowPlayingSecond {
                        self.lastNowPlayingSecond = Int(t)
                        NowPlayingCenter.shared.updatePlayback(
                            elapsed: t,
                            rate: self.speed,
                            playing: self.audio.isPlaying
                        )
                        LiveActivityController.shared.update(
                            elapsed: t,
                            playing: self.audio.isPlaying,
                            duration: self.totalDuration
                        )
                    }
                }
            }
            .store(in: &audioSubs)

        audio.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p in
                guard let self else { return }
                if self.live != nil { self.playing = p }
                // When the user pauses, immediately push progress.
                if !p && self.live?.serverEpisodeId != nil {
                    self.syncProgress(force: true)
                }
                // Reflect play/pause in lock-screen + Live Activity.
                NowPlayingCenter.shared.updatePlayback(
                    elapsed: self.currentTime,
                    rate: self.speed,
                    playing: p
                )
                LiveActivityController.shared.update(
                    elapsed: self.currentTime,
                    playing: p,
                    duration: self.totalDuration
                )
                // Mic capture follows playback: on while a podcast is playing,
                // off when paused. This is what gives the wake-word listener
                // a stream of audio buffers to scan exactly when it's useful.
                Task { @MainActor in await self.syncMicToPlayback(playing: p) }
            }
            .store(in: &audioSubs)
    }

    /// Bring MicCapture in line with the current playback state. Requests
    /// permission lazily the first time we'd start the mic.
    private func syncMicToPlayback(playing: Bool) async {
        guard live != nil else {
            MicCapture.shared.stop(force: true)
            return
        }
        if playing {
            if MicCapture.shared.currentPermission() == .undetermined {
                await MicCapture.shared.requestPermission()
            }
            MicCapture.shared.start()
        } else {
            MicCapture.shared.stop(force: true)
        }
    }

    private var lastNowPlayingSecond: Int = -1

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
        if live != nil {
            audio.seek(to: clamped)
            syncProgress(force: true)
        } else {
            currentTime = clamped
        }
    }

    // MARK: - Library

    func reloadLibrary() async {
        libraryLoading = true
        defer { libraryLoading = false }
        do {
            library = try await CueAPI.shared.getLibrary()
        } catch {
            // Quiet on launch — the library will appear empty rather than blocking.
            print("[Cue] library reload failed: \(error)")
        }
    }

    /// Open an episode from the library — fetch transcript (cache hit) and
    /// load the player at the saved position.
    func openFromLibrary(_ item: LibraryItem) async {
        let api = CueAPI.shared
        do {
            // Get the cached transcript (or transcribe on the fly if somehow missing).
            // Library entries always have a corresponding transcript in cache
            // because they were added on transcribe success.
            var transcript: TranscribeResponse?
            for try await event in api.transcribePodcastStream(
                audioUrl: item.episode.audioUrl,
                durationSeconds: item.episode.durationSeconds
            ) {
                if case .result(let r) = event { transcript = r }
                if case .error(let m) = event {
                    print("[Cue] open from library error: \(m)")
                    return
                }
            }
            guard let transcript else { return }

            // Reconstruct the resolved-podcast model the player expects.
            let show = ResolvedShow(
                title: item.episode.showTitle,
                author: item.episode.showAuthor,
                feedUrl: item.episode.showFeedUrl ?? "",
                artworkUrl: item.episode.showArtworkUrl
            )
            let episode = ResolvedEpisode(
                title: item.episode.episodeTitle,
                audioUrl: item.episode.audioUrl,
                durationSeconds: item.episode.durationSeconds,
                pubDate: item.episode.episodePubDate,
                guid: item.episode.episodeGuid ?? "",
                description: item.episode.episodeDescription
            )
            loadLive(
                LiveEpisode(show: show, episode: episode, transcript: transcript, serverEpisodeId: item.episode.id),
                resumeAt: item.positionSeconds
            )
            // Refresh order so the just-opened episode jumps to the top.
            await reloadLibrary()
        } catch {
            print("[Cue] open from library: \(error)")
        }
    }

    func removeFromLibrary(episodeId: Int) async {
        do {
            try await CueAPI.shared.removeFromLibrary(episodeId: episodeId)
            library.removeAll { $0.episode.id == episodeId }
        } catch {
            print("[Cue] remove from library: \(error)")
        }
    }

    // MARK: - Progress sync

    private func startProgressSyncTimer() {
        // Fire every 10s; the closure only pushes when conditions are right.
        progressSyncTimer = Timer.publish(every: 10.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.syncProgress(force: false)
            }
    }

    /// PATCH the server with the current position when:
    /// - we have a live episode that's linked to a library row, AND
    /// - we're playing OR `force=true` (pause/seek/close), AND
    /// - the position differs from the last synced value by at least 2s,
    ///   OR `force=true`.
    func syncProgress(force: Bool) {
        guard let episodeId = live?.serverEpisodeId else { return }
        guard force || playing else { return }
        let position = currentTime
        if !force && abs(position - lastSyncedPosition) < 2 { return }
        lastSyncedPosition = position
        lastSyncAt = Date()
        let api = CueAPI.shared
        Task { @MainActor in
            do {
                let updated = try await api.updateProgress(episodeId: episodeId, positionSeconds: position)
                // Patch the in-memory library row so the UI shows current state.
                if let idx = library.firstIndex(where: { $0.episode.id == episodeId }) {
                    library[idx] = updated
                }
            } catch {
                // Non-fatal; we'll try again on the next tick or state change.
                print("[Cue] sync progress failed: \(error)")
            }
        }
    }

    /// Called after a successful resolve+transcribe (EntryView) or when
    /// reopening from the library. `resumeAt` is the seek position in seconds.
    func loadLive(_ live: LiveEpisode, resumeAt: Double = 0) {
        self.live = live
        self.currentTime = resumeAt
        self.qaIdx = 0
        self.lastSyncedPosition = -1
        self.lastNowPlayingSecond = -1
        if let url = URL(string: live.episode.audioUrl) {
            audio.load(url: url)
            if resumeAt > 0 { audio.seek(to: resumeAt) }
            audio.play()
            audio.setRate(Float(speed))
        }
        // Tell the OS about the new episode so the lock screen + Dynamic
        // Island show it immediately, even before audio data arrives.
        let duration = live.episode.durationSeconds ?? live.transcript.durationSeconds
        NowPlayingCenter.shared.setEpisode(
            title: live.episode.title,
            show: live.show.title,
            duration: duration
        )
        LiveActivityController.shared.start(
            show: live.show.title,
            episode: live.episode.title,
            duration: duration ?? 0,
            elapsed: resumeAt
        )
        openPlayer()
    }

    func minimizePlayerAndSync() {
        syncProgress(force: true)
        minimizePlayer()
    }

    /// Tear down playback completely (called when user explicitly stops/clears).
    func endPlayback() {
        syncProgress(force: true)
        audio.unload()
        live = nil
        playing = false
        currentTime = 0
        NowPlayingCenter.shared.clear()
        LiveActivityController.shared.end()
        MicCapture.shared.stop(force: true)
        minimizePlayer()
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

    /// Height to leave clear at the bottom of any scroll view so its content
    /// isn't covered by the tab bar (always) + mini player bar (when an
    /// episode is loaded).
    var bottomDockHeight: CGFloat {
        live != nil && !playerOpen
            ? Geo.tabBarHeight + Geo.miniPlayerHeight - 2
            : Geo.tabBarHeight
    }

    /// True iff the given library episode is what's loaded in the player
    /// right now.
    func isLive(episodeId: Int) -> Bool {
        live?.serverEpisodeId == episodeId
    }

    /// True iff this episode is loaded AND currently playing. Driven by the
    /// mirrored `playing` flag (not `audio.isPlaying` directly) so SwiftUI
    /// reactively re-renders when playback state changes.
    func isPlaying(episodeId: Int) -> Bool {
        isLive(episodeId: episodeId) && playing
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

#if DEBUG
/// Tiny helper to count buffers from the audio thread without tripping
/// Swift 6 sendability rules. Internally synchronized with a lock.
private final class MicCaptureDiag: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var bufferCount = 0
    nonisolated(unsafe) private var lastLogAt = Date(timeIntervalSince1970: 0)

    nonisolated func tick(frames: Int, sampleRate: Double) {
        lock.lock()
        bufferCount += 1
        let now = Date()
        if now.timeIntervalSince(lastLogAt) >= 2.0 {
            lastLogAt = now
            let count = bufferCount
            lock.unlock()
            print("[MicCapture diag] \(count) buffers · \(frames) frames @ \(Int(sampleRate)) Hz")
        } else {
            lock.unlock()
        }
    }
}
#endif
