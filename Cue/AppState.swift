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
    /// Lags `voiceOpen` by the shade's animation duration on open. Used to
    /// gate the in-place control morph (scrubber fill → waveform, play
    /// button → mic orb) so the white scrubber thumb isn't briefly
    /// bisected by the appearing grey track mid-transition.
    @Published var voiceMorphActive: Bool = false

    /// True while the wake-word engine is listening. Drives any UI affordance
    /// (e.g. a "listening" indicator on the mic button).
    @Published private(set) var wakeArmed: Bool = false

    @Published var currentTime: Double = 0
    @Published var playing: Bool = false
    @Published var speedIdx: Int = AppState.loadSpeedIdx() {
        didSet { AppState.saveSpeedIdx(speedIdx) }
    }

    private static let speedIdxKey = "cue.speedIdx"

    private static func loadSpeedIdx() -> Int {
        let raw = UserDefaults.standard.integer(forKey: speedIdxKey)
        guard raw >= 0, raw < Speeds.values.count else { return 0 }
        return raw
    }

    private static func saveSpeedIdx(_ idx: Int) {
        UserDefaults.standard.set(idx, forKey: speedIdxKey)
    }

    @Published var paletteName: PaletteName = .ambient

    @Published var loadPhase: LoadPhase = .idle
    @Published var live: LiveEpisode?

    @Published var library: [LibraryItem] = []
    @Published var libraryLoading: Bool = false

    /// Active OpenAI Realtime session, set while VoiceAgentView is on screen.
    /// `nil` when the voice agent is closed, or when we opened the agent
    /// without a live episode (canned-sample mode — no transcript to mint
    /// a session against).
    @Published var voiceSession: RealtimeVoiceSession?

    let audio = AudioPlayer()
    let wake = WakeWordEngine()
    /// Mirrors the scene phase so updateWakeArmed() knows whether to listen.
    /// RootView pushes updates via sceneDidChange(active:).
    private var scenePhaseActive: Bool = true
    /// Edge tracker — true iff we currently hold a MicCapture ref for the
    /// wake engine. Used to issue exactly one start()/stop() per transition.
    private var micArmedForWake: Bool = false
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

        wake.onDetect = { [weak self] in self?.openMic() }

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
            }
            .store(in: &audioSubs)
    }

    // MARK: - Wake-word arming
    //
    // MicCapture and WakeWordEngine have *different* lifecycles:
    //
    //   - MicCapture runs whenever the full PlayerView is on screen with
    //     an episode loaded and the scene is active — INCLUDING during
    //     voice mode. The unified pipeline (CueAudioDevice) needs the
    //     engine alive to render WebRTC's TTS output through
    //     `mainMixerNode`. Stopping it on voice-mode entry breaks playback.
    //
    //   - WakeWordEngine only listens in playback mode (voiceOpen == false).
    //     The assistant's TTS shouldn't be re-detected as a wake phrase.

    /// Called by RootView on scene-phase transitions.
    func sceneDidChange(active: Bool) {
        scenePhaseActive = active
        updateWakeArmed()
    }

    /// Reconcile MicCapture + WakeWordEngine to the current UI state.
    /// Idempotent. Called from every state transition that affects either.
    private func updateWakeArmed() {
        let shouldRunMic = live != nil && playerOpen && scenePhaseActive
        let shouldArmWake = shouldRunMic && !voiceOpen

        if shouldRunMic != micArmedForWake {
            micArmedForWake = shouldRunMic
            if shouldRunMic {
                Task { @MainActor in
                    if MicCapture.shared.currentPermission() == .undetermined {
                        await MicCapture.shared.requestPermission()
                    }
                    guard self.micArmedForWake else { return }
                    MicCapture.shared.start()
                }
            } else {
                MicCapture.shared.stop()
            }
        }

        if shouldArmWake != wakeArmed {
            wakeArmed = shouldArmWake
            if shouldArmWake {
                wake.start()
            } else {
                wake.stop()
            }
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

    func openPlayer() {
        withAnimation(.easeOut(duration: 0.28)) { playerOpen = true }
        updateWakeArmed()
    }
    func minimizePlayer() {
        withAnimation(.easeOut(duration: 0.28)) { playerOpen = false }
        updateWakeArmed()
    }

    func openMic() {
        withAnimation(.easeOut(duration: 0.32)) { voiceOpen = true }
        // Pause podcast while the agent is open.
        if live != nil { audio.pause() }
        // Hand the mic off to the realtime session — wake should not keep
        // tapping the input bus while the agent is on screen.
        updateWakeArmed()

        // Defer the in-place control morph until the shade has fully
        // covered the player below. Without this lag, the white scrubber
        // thumb is briefly visible on top of the appearing grey track —
        // looks like the thumb is bisected mid-transition. 0.32s matches
        // the shade's animation duration above.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard let self, self.voiceOpen else { return }
            withAnimation(.easeInOut(duration: 0.25)) { self.voiceMorphActive = true }
        }

        // Spin up a real OpenAI Realtime session whenever we have a live
        // episode. Without `live` there's no audioUrl / transcript to mint
        // a session against, so we leave voiceSession nil and let the view
        // render an empty / "load an episode first" state.
        guard let live, let pausedAt = currentPausedSeconds() else {
            voiceSession = nil
            return
        }
        let session = RealtimeVoiceSession(api: CueAPI.shared, state: self)
        voiceSession = session
        let ctx = RealtimeVoiceSession.Context(
            audioUrl: live.episode.audioUrl,
            pausedAtSeconds: pausedAt,
            totalDurationSeconds: totalDuration > 0 ? totalDuration : nil,
            episodeTitle: live.episode.title,
            showTitle: live.show.title
        )
        Task { await session.start(context: ctx) }
    }
    func resumeAfterVoice() {
        // Tear the realtime session down first so it stops claiming the
        // mic / restores audio-session config before AudioPlayer resumes.
        voiceSession?.stop()
        voiceSession = nil

        withAnimation(.easeOut(duration: 0.25)) {
            voiceOpen = false
            voiceMorphActive = false
        }
        if live != nil { audio.play(); audio.setRate(Float(speed)) }
        else { playing = true }
        // Re-arm wake after a brief delay so the tail of the realtime
        // session's TTS audio doesn't immediately re-trigger.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.updateWakeArmed()
        }
    }

    /// AVPlayer's currentTime when live; falls back to the simulated
    /// time otherwise. Returns nil when neither is meaningful (no live
    /// episode loaded).
    private func currentPausedSeconds() -> Double? {
        if live != nil { return audio.currentTime }
        return nil
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
