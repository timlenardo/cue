import SwiftUI
import Combine
import Observation
import AVFAudio

enum Tab: String { case listen, library, notes }

/// One row in the live "what is Whisper hearing right now" toast stack.
/// Created by `AppState.addWakeTranscript`; auto-removed after 2s.
struct WakeTranscript: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// True when the transcript matched the wake-word trigger regex.
    /// Renders a green check next to the text so dev can eyeball at a
    /// glance which transcripts would actually have fired the agent.
    let isHit: Bool
}

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
    var serverEpisodeId: Int?

    /// Word-level timeline in seconds. Computed once in `init` from the raw
    /// Whisper response and cached so view bodies don't re-allocate a
    /// thousands-element array on every 10 Hz `currentTime` tick.
    let liveWords: [TranscriptWord]
    /// Sentence-level timeline (1 sentence = 1 Whisper segment). Cached for
    /// the same reason as `liveWords`.
    let liveSentences: [TranscriptSentence]
    /// Whisper doesn't emit chapters; synthesize a single marker so the
    /// chapter label always has something to display.
    let liveChapters: [Chapter]

    init(show: ResolvedShow, episode: ResolvedEpisode, transcript: TranscribeResponse, serverEpisodeId: Int? = nil) {
        self.show = show
        self.episode = episode
        self.transcript = transcript
        self.serverEpisodeId = serverEpisodeId

        let words = Self.buildWords(from: transcript)
        var bySentence: [Int: [TranscriptWord]] = [:]
        for w in words { bySentence[w.sentenceIdx, default: []].append(w) }
        let sentences: [TranscriptSentence] = transcript.segments.enumerated().map { idx, seg in
            TranscriptSentence(
                id: idx,
                speaker: seg.speaker,
                start: Double(seg.startMs) / 1000.0,
                end: Double(seg.endMs) / 1000.0,
                words: bySentence[idx] ?? []
            )
        }
        self.liveWords = words
        self.liveSentences = sentences
        self.liveChapters = [Chapter(t: 0, title: episode.title)]
    }

    private static func buildWords(from transcript: TranscribeResponse) -> [TranscriptWord] {
        let segments = transcript.segments
        let rawWords = transcript.words
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

    /// Largest index i such that starts[i] <= ms. -1 if before all.
    private static func lastIndex(at ms: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= ms { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }
}

@MainActor
@Observable
final class AppState {
    var tab: Tab = .listen
    var playerOpen: Bool = false
    var voiceOpen: Bool = false
    /// Lags `voiceOpen` by the shade's animation duration on open. Used to
    /// gate the in-place control morph (scrubber fill → waveform, play
    /// button → mic orb) so the white scrubber thumb isn't briefly
    /// bisected by the appearing grey track mid-transition.
    var voiceMorphActive: Bool = false
    /// Drives the play dot, green progress fill, and play icon. Fades to
    /// false during phase 1 of opening the voice agent, then back to true
    /// during phase 2 of closing it. Lets the dot + green fade out before
    /// the waveform takes their slot, killing the bisection on the scrubber.
    var playbackDetailsVisible: Bool = true
    /// Snapshot of `playing` at the moment `voiceOpen` flipped true. The
    /// play button's glyph reads from this while voice mode is open, so
    /// the pause→play flip caused by `audio.pause()` inside
    /// `openVoiceAgent` doesn't change the icon mid-transition.
    var playingAtVoiceOpen: Bool = false

    /// Drives the play button glyph (pause vs play). Mirrors `playing`
    /// normally; pins to its pre-voiceOpen value while voice mode is open.
    var iconPlaying: Bool { voiceOpen ? playingAtVoiceOpen : playing }

    /// True while the wake-word engine is listening. Drives any UI affordance
    /// (e.g. a "listening" indicator on the mic button).
    private(set) var wakeArmed: Bool = false

    /// Settings sheet visibility, driven by the gear button in EntryView.
    var settingsOpen: Bool = false

    /// Dev toggle: when on, force-arm the wake engine (regardless of whether
    /// an episode is loaded) and surface every Whisper transcript as a toast
    /// over the app via `wakeTranscripts`. Persisted across launches.
    var wakeTrackingEnabled: Bool = AppState.loadWakeTracking() {
        didSet {
            guard oldValue != wakeTrackingEnabled else { return }
            AppState.saveWakeTracking(wakeTrackingEnabled)
            if !wakeTrackingEnabled { wakeTranscripts.removeAll() }
            updateWakeArmed()
        }
    }

    /// Live list of in-flight transcript toasts. Each entry self-dismisses
    /// after 2s; the UI renders the array in render order, stacked.
    var wakeTranscripts: [WakeTranscript] = []

    private static let wakeTrackingKey = "cue.wakeTracking"
    private static func loadWakeTracking() -> Bool {
        UserDefaults.standard.bool(forKey: wakeTrackingKey)
    }
    private static func saveWakeTracking(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: wakeTrackingKey)
    }

    /// Dev toggle: when on, render a small HUD with the live AVAudioSession
    /// mode and VPIO state. Persisted across launches.
    var audioSessionDebugEnabled: Bool = AppState.loadAudioSessionDebug() {
        didSet {
            guard oldValue != audioSessionDebugEnabled else { return }
            AppState.saveAudioSessionDebug(audioSessionDebugEnabled)
        }
    }

    private static let audioSessionDebugKey = "cue.audioSessionDebug"
    private static func loadAudioSessionDebug() -> Bool {
        UserDefaults.standard.bool(forKey: audioSessionDebugKey)
    }
    private static func saveAudioSessionDebug(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: audioSessionDebugKey)
    }

    var currentTime: Double = 0
    var playing: Bool = false
    var speedIdx: Int = AppState.loadSpeedIdx() {
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

    var paletteName: PaletteName = .ambient

    var loadPhase: LoadPhase = .idle
    var live: LiveEpisode?

    var library: [LibraryItem] = []
    var libraryLoading: Bool = false

    /// Active OpenAI Realtime session, set while VoiceAgentView is on screen.
    /// `nil` when the voice agent is closed, or when we opened the agent
    /// without a live episode (canned-sample mode — no transcript to mint
    /// a session against).
    var voiceSession: RealtimeVoiceSession?

    @ObservationIgnored let audio = AudioPlayer()
    @ObservationIgnored let wake = WakeWordEngine()
    /// Mirrors the scene phase so updateWakeArmed() knows whether to listen.
    /// RootView pushes updates via sceneDidChange(active:).
    @ObservationIgnored private var scenePhaseActive: Bool = true
    /// Edge tracker — true iff we currently hold a MicCapture ref for the
    /// wake engine. Used to issue exactly one start()/stop() per transition.
    @ObservationIgnored private var micArmedForWake: Bool = false
    @ObservationIgnored private var audioSubs: Set<AnyCancellable> = []
    @ObservationIgnored private var progressSyncTimer: AnyCancellable?
    @ObservationIgnored private var lastSyncedPosition: Double = -1
    @ObservationIgnored private var lastSyncAt: Date?

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

    @ObservationIgnored private var simulatedTimer: AnyCancellable?
    @ObservationIgnored private var lastSimulatedTick: Date?

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

        wake.onDetect = { [weak self] in self?.openVoiceAgent() }
        wake.onTranscript = { [weak self] text, isHit in
            self?.addWakeTranscript(text, isHit: isHit)
        }

        // Mirror AudioPlayer's time + playing state into AppState so the
        // transcript / progress views update reactively. `AudioPlayer`
        // already publishes on the main thread (its `addPeriodicTimeObserver`
        // is registered with `queue: .main` and `pause()`/`play()` run on
        // the main actor), so we don't need a `.receive(on:)` hop — that
        // was burning 20 GCD round-trips/sec while playing.
        audio.$currentTime
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

        // If the dev wake-tracking toggle is on from a prior launch, arm the
        // engine immediately — without this, the toggle silently does
        // nothing until the user loads a podcast or flips it off and on.
        if wakeTrackingEnabled { updateWakeArmed() }
    }

    // MARK: - Wake-word arming
    //
    // Simple rule: MicCapture + WakeWordEngine run as long as an episode
    // is loaded. Both stay alive through:
    //   - background / lock-screen (driving with a locked phone: user
    //     should be able to say "qq" / "cue cue" and trigger voice mode
    //     without unlocking)
    //   - SwiftUI scenePhase flapping on innocuous events
    //   - mini-player vs full-player view changes
    //
    // The wake engine pauses only while voice mode is open, so the AI's
    // TTS doesn't re-trigger a wake during its own response.
    //
    // `UIBackgroundModes: audio` (set in Info.plist) is what lets iOS
    // allow the mic to keep recording in background.

    /// Kept for future scene-phase-aware features (none currently). Wake
    /// detection deliberately ignores scene phase so it works on a locked
    /// phone.
    func sceneDidChange(active: Bool) {
        scenePhaseActive = active
    }

    /// Push a transcript into the toast stack and schedule its 2s removal.
    /// No-op when the dev tracking toggle is off. Consecutive duplicates
    /// (same text as the most recent toast still on screen) are coalesced
    /// — Whisper's 2s rolling window emits the same utterance ~4-8 times in
    /// a row, and showing each repeat would flood the stack.
    func addWakeTranscript(_ text: String, isHit: Bool) {
        guard wakeTrackingEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let last = wakeTranscripts.last, last.text == trimmed, last.isHit == isHit {
            return
        }
        let toast = WakeTranscript(text: trimmed, isHit: isHit)
        withAnimation(.easeOut(duration: 0.18)) {
            wakeTranscripts.append(toast)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            withAnimation(.easeIn(duration: 0.22)) {
                self.wakeTranscripts.removeAll { $0.id == toast.id }
            }
        }
    }

    /// Reconcile MicCapture + WakeWordEngine to the current state.
    /// Idempotent. Called from any transition that changes `live` or
    /// `voiceOpen`.
    private func updateWakeArmed() {
        // wakeTrackingEnabled force-arms the engine even when no episode is
        // loaded, so dev can verify what Whisper is hearing without first
        // having to start a podcast.
        let shouldRunMic = live != nil || wakeTrackingEnabled
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

    @ObservationIgnored private var lastNowPlayingSecond: Int = -1

    /// Starts the 30 Hz canned-sample tick. Only ever needed when there's
    /// no live episode — gets cancelled in `loadLive` and restarted in
    /// `endPlayback` so we don't pump a Combine sink 30×/sec during real
    /// playback (the sink no-ops then, but the timer still fires).
    private func startSimulatedTimer() {
        guard simulatedTimer == nil else { return }
        simulatedTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.simulatedTick() }
    }

    private func stopSimulatedTimer() {
        simulatedTimer?.cancel()
        simulatedTimer = nil
        lastSimulatedTick = nil
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

    func openVoiceAgent() {
        // Freeze the play button glyph at its current value so the
        // pause→play flip from `audio.pause()` below doesn't mutate the
        // icon mid-transition. The play button isn't rendered while
        // voiceOpen is true, but this keeps the binding clean.
        playingAtVoiceOpen = playing

        // Phase 1: shade dims (0.32s) and the playback details (scrubber
        // dot + green fill) fade out (0.25s). By the time phase 2 runs,
        // the dot is at opacity 0 — so the waveform's appearance can't
        // visually bisect it.
        withAnimation(.easeOut(duration: 0.32)) { voiceOpen = true }
        withAnimation(.easeInOut(duration: 0.25)) { playbackDetailsVisible = false }

        // Pause podcast while the agent is open.
        if live != nil { audio.pause() }
        // Hand the mic off to the realtime session — wake should not keep
        // tapping the input bus while the agent is on screen.
        updateWakeArmed()

        // Phase 2: after phase-1 fade-out lands, swap in the waveform.
        // 270ms = 250ms fade-out + 20ms buffer so the opacity has fully
        // committed before the structural swap fires.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 270_000_000)
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
    func closeVoiceAgent() {
        // Tear the realtime session down first so it stops claiming the
        // mic / restores audio-session config before AudioPlayer resumes.
        voiceSession?.stop()
        voiceSession = nil

        // Phase 1 (reversed): waveform fades out. The shade and playback
        // details stay put during this phase.
        withAnimation(.easeInOut(duration: 0.25)) { voiceMorphActive = false }

        // Phase 2 (reversed): once the waveform is gone, lift the shade
        // and fade the playback details back in.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 270_000_000)
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self.voiceOpen = false
                self.playbackDetailsVisible = true
                // Defensive: if an in-flight open-task fired during our
                // 270ms gap and re-flipped morphActive, clear it here so
                // the player can't end up closed-with-waveform-stuck.
                self.voiceMorphActive = false
            }
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
                description: item.episode.episodeDescription,
                artworkUrl: item.episode.episodeArtworkUrl ?? item.episode.showArtworkUrl
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
        // AVPlayer drives `currentTime` from here on — kill the canned-
        // sample 30 Hz pump.
        stopSimulatedTimer()
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
        // Canned-sample mode is back in effect — re-arm the 30 Hz pump.
        startSimulatedTimer()
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
