import SwiftUI
import UIKit
import Combine
import Observation
import AVFAudio

enum Tab: String { case listen, library, notes }

private enum WakeEngineKind: Equatable {
    case whisperKit
    case forcedDecode
}

/// Peak amplitude / clip-rate snapshot for the audio window that produced
/// a given wake transcript. Surfaced behind the dev "audio levels" toggle
/// so we can verify Whisper is getting input in its training distribution
/// (roughly -10 to -3 dBFS for speech).
///
/// Pre-gain = what VPIO handed us; post-gain = what we'd feed Whisper if
/// we didn't hard-clip at ±1.0. The clip rate tells us how often we are
/// clipping after the software gain multiplier.
struct AudioLevelStats: Equatable, Sendable {
    /// Max |sample| across the window, BEFORE software gain. Linear 0...1.
    let preGainPeak: Float
    /// Max |sample * gain| across the window, BEFORE the ±1.0 clip. Can
    /// exceed 1.0 — that's the whole point of tracking it pre-clip.
    let postGainPeak: Float
    /// Number of samples whose post-gain magnitude hit or exceeded 1.0
    /// (i.e. would be clipped). 0 if the gain is conservative.
    let clippedCount: Int
    /// Total samples observed across the window. Used to compute clip rate.
    let sampleCount: Int

    var clipRate: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(clippedCount) / Double(sampleCount)
    }
    var preGainDBFS: Double { Self.dBFS(preGainPeak) }
    var postGainDBFS: Double { Self.dBFS(postGainPeak) }

    /// 20·log10(x), floored at -120 dB so log(0) doesn't return -inf when
    /// the window was pure silence.
    static func dBFS(_ x: Float) -> Double {
        20 * log10(max(Double(x), 1e-6))
    }
}

/// One row in the live "what is Whisper hearing right now" toast stack.
/// Created by `AppState.addWakeTranscript`; auto-removed after 2s.
struct WakeTranscript: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// True when the transcript matched the wake-word trigger regex.
    /// Renders a green check next to the text so dev can eyeball at a
    /// glance which transcripts would actually have fired the agent.
    let isHit: Bool
    /// Audio level stats for the window that produced this transcript.
    /// Nil when no audio buffers were observed since the last inference
    /// (e.g. inference fired off the boot-time padding). Rendered only
    /// when `audioLevelsDebugEnabled` is on.
    let levels: AudioLevelStats?
}

enum LoadPhase: Equatable {
    case idle
    case resolving
    /// `progress` is 0..1 when known, nil before chunks are reported.
    case transcribing(stage: String, progress: Double?, chunkCount: Int?)
    case error(String)
}

struct TranscriptIndexingProgress: Equatable {
    let stage: String
    let completedCount: Int
    let chunkCount: Int?

    var fraction: Double? {
        guard let chunkCount, chunkCount > 0 else { return nil }
        return min(1, max(0, Double(completedCount) / Double(chunkCount)))
    }
}

struct LiveEpisode {
    let show: ResolvedShow
    let episode: ResolvedEpisode
    let transcript: TranscribeResponse
    let transcriptReadyForVoice: Bool
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

    init(
        show: ResolvedShow,
        episode: ResolvedEpisode,
        transcript: TranscribeResponse,
        serverEpisodeId: Int? = nil,
        transcriptReadyForVoice: Bool = true
    ) {
        self.show = show
        self.episode = episode
        self.transcript = transcript
        self.transcriptReadyForVoice = transcriptReadyForVoice
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

/// How a voice session was opened. Stamped on `voice_session_opened` /
/// `_closed` PostHog events so Dashboard 3 can break "voice users" down by
/// wake-word vs mic-tap entry.
enum VoiceEntrySource: String {
    case wakeWord = "wake_word"
    case micButton = "mic_button"
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

    /// Profile sheet visibility, driven by the person button in EntryView.
    var profileOpen: Bool = false

    /// Dev toggle: when on, surface every Whisper transcript as a toast over
    /// the app via `wakeTranscripts`. Wake engine arming is NOT affected —
    /// the engine still requires a loaded episode. Persisted across launches.
    var wakeTrackingEnabled: Bool = AppState.loadWakeTracking() {
        didSet {
            guard oldValue != wakeTrackingEnabled else { return }
            AppState.saveWakeTracking(wakeTrackingEnabled)
            if !wakeTrackingEnabled { wakeTranscripts.removeAll() }
            Analytics.shared.track(
                "wake_tracking_toggled",
                properties: ["enabled": wakeTrackingEnabled]
            )
        }
    }

    // MARK: - Analytics session state
    //
    // Tracked per-live-episode and per-voice-session so we can stamp
    // duration / utterance counts onto the PostHog `_closed` event without
    // forcing the caller to remember.
    private var voiceSessionStartedAt: Date?
    private var voiceSessionEntry: VoiceEntrySource?
    private var voiceUtteranceCount: Int = 0
    private var voiceToolCallCount: Int = 0
    /// True once the FIRST `playback_started` event has fired for the
    /// currently-loaded episode. Subsequent transitions into `isPlaying` fire
    /// `playback_resumed` instead.
    private var firstPlayFiredForLive: Bool = false
    /// True once `playback_completed` has fired for the currently-loaded
    /// episode. Prevents duplicate 90% fires from the per-tick sink.
    private var completionFiredForLive: Bool = false

    /// Live list of in-flight transcript toasts. Each entry self-dismisses
    /// after 2s; the UI renders the array in render order, stacked.
    var wakeTranscripts: [WakeTranscript] = []

    /// Throttle for non-hit toasts. Whisper runs at ~4 Hz and emits nearly
    /// identical text each pass; without this, the toast stack thrashes
    /// SwiftUI animations 4×/sec whenever someone is speaking nearby.
    @ObservationIgnored private var lastNonHitToastAt: Date = .distantPast

    private static let wakeTrackingKey = "cue.wakeTracking"
    private static func loadWakeTracking() -> Bool {
        UserDefaults.standard.bool(forKey: wakeTrackingKey)
    }
    private static func saveWakeTracking(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: wakeTrackingKey)
    }

    /// Dev toggle: when on, the wake-word engine is held down even if an
    /// episode is loaded. Mic capture stays up (voice mode can still be
    /// opened manually), but ambient speech can't open the AI. Persisted
    /// across launches.
    var wakePaused: Bool = AppState.loadWakePaused() {
        didSet {
            guard oldValue != wakePaused else { return }
            AppState.saveWakePaused(wakePaused)
            updateWakeArmed()
        }
    }

    private static let wakePausedKey = "cue.wakePaused"
    private static func loadWakePaused() -> Bool {
        UserDefaults.standard.bool(forKey: wakePausedKey)
    }
    private static func saveWakePaused(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: wakePausedKey)
    }

    /// Dev toggle: when on, use the whisper-tiny CoreML forced-decode scorer
    /// (`WhisperKwsEngine`) while the app is active. When the app resigns
    /// active (including lock-screen/background), we fall back to the older
    /// WhisperKit free-decode + regex path (`WakeWordEngine`) because iOS
    /// rejects background Metal/GPU work. Defaults on for new installs and
    /// persists across launches once changed.
    var forceDecodeWakeEnabled: Bool = AppState.loadForceDecodeWake() {
        didSet {
            guard oldValue != forceDecodeWakeEnabled else { return }
            AppState.saveForceDecodeWake(forceDecodeWakeEnabled)
            reconcileWakeEngineForCurrentState()
        }
    }

    private static let forceDecodeWakeKey = "cue.forceDecodeWakeEnabled"
    private static func loadForceDecodeWake() -> Bool {
        if let stored = UserDefaults.standard.object(forKey: forceDecodeWakeKey) as? Bool {
            return stored
        }
        return true
    }
    private static func saveForceDecodeWake(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: forceDecodeWakeKey)
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

    /// Dev toggle: when on, the wake-word transcript toasts include the
    /// peak amplitudes (pre-gain → post-gain pre-clip, in dBFS) and the
    /// clip-rate of the audio window. Lets us verify the 3× software gain
    /// is landing us in Whisper's training distribution.
    /// Only meaningful when `wakeTrackingEnabled` is also on — the levels
    /// piggyback on the wake transcript toasts. Persisted across launches.
    var audioLevelsDebugEnabled: Bool = AppState.loadAudioLevelsDebug() {
        didSet {
            guard oldValue != audioLevelsDebugEnabled else { return }
            AppState.saveAudioLevelsDebug(audioLevelsDebugEnabled)
        }
    }

    private static let audioLevelsDebugKey = "cue.audioLevelsDebug"
    private static func loadAudioLevelsDebug() -> Bool {
        UserDefaults.standard.bool(forKey: audioLevelsDebugKey)
    }
    private static func saveAudioLevelsDebug(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: audioLevelsDebugKey)
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

    /// Flat list of every saved note for the user, newest-first, with episode
    /// metadata embedded. Powers the Notes tab.
    var allNotes: [ServerNoteWithEpisode] = []
    var notesLoading: Bool = false

    /// Per-episode notes keyed by serverEpisodeId. Populated lazily when an
    /// episode goes live so the player scrubber can render its markers
    /// without round-tripping every time the live state changes.
    var notesByEpisode: [Int: [ServerNote]] = [:]

    /// Active OpenAI Realtime session, set while VoiceAgentView is on screen.
    /// `nil` when the voice agent is closed, or when we opened the agent
    /// without a live episode (canned-sample mode — no transcript to mint
    /// a session against).
    var voiceSession: RealtimeVoiceSession?

    @ObservationIgnored let audio = AudioPlayer()
    /// Effective wake engine currently installed. This follows the persisted
    /// `forceDecodeWakeEnabled` preference only while the app is active; the
    /// lock-screen/background path always uses WhisperKit so it does not submit
    /// GPU work from the background.
    @ObservationIgnored private var wakeEngineKind: WakeEngineKind = AppState.initialWakeEngineKind()
    /// Current wake engine. `var` (not `let`) so scene phase and the dev
    /// `forceDecodeWakeEnabled` toggle can swap implementations at runtime.
    /// Both implementations conform to `WakeEngine`, so AppState wiring sites
    /// (callbacks, start/stop) don't care which.
    @ObservationIgnored var wake: WakeEngine = AppState.makeWakeEngine(kind: AppState.initialWakeEngineKind())
    /// Incremented each time callbacks are rebound so in-flight completions
    /// from a stopped/replaced engine cannot open voice mode or surface stale
    /// debug toasts.
    @ObservationIgnored private var wakeCallbackGeneration: UInt64 = 0

    private static func initialWakeEngineKind() -> WakeEngineKind {
        desiredWakeEngineKind(forceDecodeEnabled: loadForceDecodeWake(), scenePhaseActive: true)
    }

    private static func desiredWakeEngineKind(
        forceDecodeEnabled: Bool,
        scenePhaseActive: Bool
    ) -> WakeEngineKind {
        forceDecodeEnabled && scenePhaseActive ? .forcedDecode : .whisperKit
    }

    private static func makeWakeEngine(kind: WakeEngineKind) -> WakeEngine {
        switch kind {
        case .forcedDecode:
            return WhisperKwsEngine()
        case .whisperKit:
            return WakeWordEngine()
        }
    }
    /// Mirrors the scene phase so updateWakeArmed() knows whether to listen.
    /// RootView pushes updates via sceneDidChange(active:).
    @ObservationIgnored private var scenePhaseActive: Bool = true
    /// Edge tracker — true iff we currently hold a MicCapture ref for the
    /// wake engine. Used to issue exactly one start()/stop() per transition.
    @ObservationIgnored private var micArmedForWake: Bool = false
    @ObservationIgnored private var audioSubs: Set<AnyCancellable> = []
    @ObservationIgnored private var progressSyncTimer: AnyCancellable?
    /// Polls `/v1/library` every 5s while the Library tab is foregrounded
    /// and at least one row is in `processing`. Drives the article-TTS
    /// "Generating audio…" → "Ready to play" transition without APNs.
    @ObservationIgnored private var libraryPollTimer: AnyCancellable?
    /// Mirrors LibraryView's onAppear/onDisappear so updateLibraryPolling
    /// only ticks while the user is actually on the tab.
    @ObservationIgnored private var libraryTabVisible: Bool = false
    /// Polls voiceSession.inputLevel at 5Hz while voice mode is open and
    /// forwards it to the Live Activity glow channel. Throttling /
    /// delta-gating happens inside `LiveActivityController.pushGlow`.
    @ObservationIgnored private var liveActivityGlowTimer: Timer?
    @ObservationIgnored private var transcriptIndexingTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastSyncedPosition: Double = -1
    @ObservationIgnored private var lastSyncAt: Date?

    var liveTranscriptIndexingProgress: TranscriptIndexingProgress?
    var palette: Palette { paletteName.palette }
    var speed: Double { Speeds.values[speedIdx] }
    var liveTranscriptReady: Bool {
        guard let live else { return false }
        return live.transcriptReadyForVoice
    }
    var liveTranscriptIndexingActive: Bool {
        guard live != nil else { return false }
        return !liveTranscriptReady
    }
    var liveTranscriptIndexedThrough: Double? {
        if let lastSentence = live?.liveSentences.last { return lastSentence.end }
        return live?.liveWords.last?.end
    }
    var playbackIsAheadOfIndexedTranscript: Bool {
        guard liveTranscriptIndexingActive else { return false }
        guard let indexedThrough = liveTranscriptIndexedThrough else { return false }
        return currentTime > indexedThrough + 1.5
    }

    var wakeTrackingSubtitle: String {
        let activeKind = Self.desiredWakeEngineKind(
            forceDecodeEnabled: forceDecodeWakeEnabled,
            scenePhaseActive: scenePhaseActive
        )
        let triggers = activeKind == .forcedDecode
            ? WhisperKwsEngine.userVisibleTriggers
            : WakeWordEngine.userVisibleTriggers
        if activeKind == .forcedDecode {
            return "Show every forced-decode keyword score as a toast. Scores at or above threshold that pass debounce get a green check. Triggers (\(triggers)). Requires a loaded episode — wake only runs during playback. Lock screen falls back to WhisperKit to avoid background GPU work."
        }
        return "Show every transcript the wake-word engine picks up as a toast. Trigger matches that pass debounce get a green check. Triggers (\(triggers)). Requires a loaded episode — wake only runs during playback."
    }

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

        // Stop the 5Hz LA glow sampler if the activity goes away externally
        // (system tear-down, user swipe-away, budget exhaustion). Without
        // this the Timer would keep firing against a nil activity.
        LiveActivityController.shared.onActivityEnded = { [weak self] in
            self?.stopLiveActivityGlowSampler()
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: .cuePlayPause, object: nil, queue: .main) { [weak self] _ in
            self?.togglePlay()
        }
        nc.addObserver(forName: .cueSkip15Back, object: nil, queue: .main) { [weak self] _ in
            self?.skipBack15()
        }
        nc.addObserver(forName: .cueSkip15Forward, object: nil, queue: .main) { [weak self] _ in
            self?.skipFwd15()
        }
        nc.addObserver(forName: .cueCloseVoiceAgent, object: nil, queue: .main) { [weak self] _ in
            // Posted from the LA Resume button. Idempotent — guard against
            // a duplicate close when voice mode is already closing.
            guard let self, self.voiceOpen else { return }
            self.closeVoiceAgent()
        }

        bindWakeCallbacks()

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
                    // 90% completion — fire once per loaded episode. Gated
                    // by duration > 0 so we don't divide-by-zero before the
                    // player learns the asset length.
                    if !self.completionFiredForLive,
                       self.totalDuration > 0,
                       t / self.totalDuration >= 0.9 {
                        self.completionFiredForLive = true
                        Analytics.shared.track(
                            "playback_completed",
                            properties: [
                                "episode_id": self.live?.serverEpisodeId,
                                "duration_s": self.totalDuration,
                            ]
                        )
                    }
                }
            }
            .store(in: &audioSubs)

        audio.$isPlaying
            .sink { [weak self] p in
                guard let self else { return }
                if self.live != nil { self.playing = p }
                // PostHog: distinguish first-play-on-this-episode from resume.
                // loadLive resets firstPlayFiredForLive=false; the first time
                // isPlaying flips true after that, we treat as "started".
                if self.live != nil {
                    if p {
                        let event = self.firstPlayFiredForLive
                            ? "playback_resumed"
                            : "playback_started"
                        self.firstPlayFiredForLive = true
                        Analytics.shared.track(
                            event,
                            properties: [
                                "episode_id": self.live?.serverEpisodeId,
                                "position_s": self.currentTime,
                            ]
                        )
                    } else {
                        Analytics.shared.track(
                            "playback_paused",
                            properties: [
                                "episode_id": self.live?.serverEpisodeId,
                                "position_s": self.currentTime,
                            ]
                        )
                    }
                }
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
    // Simple rule: MicCapture + WakeWordEngine run as long as an episode
    // is loaded. Both stay alive through:
    //   - background / lock-screen (driving with a locked phone: user
    //     should be able to say "orbit" and trigger voice mode
    //     without unlocking)
    //   - SwiftUI scenePhase flapping on innocuous events
    //   - mini-player vs full-player view changes
    //
    // The wake engine pauses only while voice mode is open, so the AI's
    // TTS doesn't re-trigger a wake during its own response.
    //
    // `UIBackgroundModes: audio` (set in Info.plist) is what lets iOS
    // allow the mic to keep recording in background.

    /// Wake arming deliberately ignores scene phase so it works on a locked
    /// phone, but the chosen engine does not: forced-decode uses CoreML GPU
    /// work, so it is foreground-only and we swap to WhisperKit before the app
    /// backgrounds. The Live Activity glow sampler also stops in background —
    /// running the 5Hz push loop there burns ActivityKit's push budget for no
    /// visible benefit (the lock screen is what the user sees while
    /// backgrounded, and the LA there is read-only anyway).
    func sceneDidChange(active: Bool) {
        scenePhaseActive = active
        reconcileWakeEngineForCurrentState()
        if !active {
            stopLiveActivityGlowSampler()
        } else {
            if voiceOpen, voiceSession != nil {
                startLiveActivityGlowSampler()
            }
            // Per the article-TTS brief: refetch the library once on
            // foreground when any row is still processing — picks up the
            // ready/failed flip the user missed while backgrounded.
            if hasProcessingLibraryRow {
                Task { await reloadLibrary() }
            }
        }
        updateLibraryPolling()
    }

    /// Push a transcript into the toast stack and schedule its 2s removal.
    /// No-op when the dev tracking toggle is off. Consecutive duplicates
    /// (same text as the most recent toast still on screen) are coalesced
    /// — Whisper's 2s rolling window emits the same utterance ~4-8 times in
    /// a row, and showing each repeat would flood the stack.
    func addWakeTranscript(_ text: String, isHit: Bool, levels: AudioLevelStats?) {
        guard wakeTrackingEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Coalesce only on text + isHit — levels fluctuate window-to-window
        // even for identical text, but updating them on a held toast would
        // cause flicker. The first window's levels stay until the toast
        // ages out 2s later.
        if let last = wakeTranscripts.last, last.text == trimmed, last.isHit == isHit {
            return
        }
        // Whisper emits near-duplicates 4×/sec; rate-limit non-hit toasts
        // so the overlay can't thrash SwiftUI continuously. Hit toasts
        // bypass — they're already debounced 1.5s upstream in WakeWordEngine.
        if !isHit {
            let now = Date()
            guard now.timeIntervalSince(lastNonHitToastAt) >= 0.6 else { return }
            lastNonHitToastAt = now
        }
        let toast = WakeTranscript(text: trimmed, isHit: isHit, levels: levels)
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

    /// Attach `onDetect` / `onTranscript` to the current `wake` instance.
    /// Called from `init()` and re-called after a toggle or scene-phase change
    /// replaces the engine.
    @MainActor
    private func bindWakeCallbacks() {
        wakeCallbackGeneration += 1
        let generation = wakeCallbackGeneration
        wake.onDetect = { [weak self] in
            guard let self else { return }
            guard generation == self.wakeCallbackGeneration else { return }
            // Defensive: the gating in updateWakeArmed should already prevent
            // wake from listening with no episode loaded, but if an in-flight
            // inference completes after stop() (or any other edge case leaks
            // a fire), refuse to open the agent — the user has nothing
            // loaded to talk about.
            guard self.live != nil else {
                print("[wake] onDetect dropped — no live episode")
                return
            }
            guard self.wakeArmed, !self.voiceOpen, !self.wakePaused else {
                print("[wake] onDetect dropped — wake is not armed")
                return
            }
            Analytics.shared.track(
                "wake_word_triggered",
                properties: [
                    "in_app": UIApplication.shared.applicationState == .active,
                ]
            )
            self.openVoiceAgent(source: .wakeWord)
        }
        wake.onTranscript = { [weak self] text, isHit, levels in
            guard let self else { return }
            guard generation == self.wakeCallbackGeneration, self.wakeArmed else { return }
            self.addWakeTranscript(text, isHit: isHit, levels: levels)
        }
    }

    /// Reconcile the installed wake engine against the user's forced-decode
    /// preference and the current scene phase.
    @MainActor
    private func reconcileWakeEngineForCurrentState() {
        let desired = Self.desiredWakeEngineKind(
            forceDecodeEnabled: forceDecodeWakeEnabled,
            scenePhaseActive: scenePhaseActive
        )
        guard desired != wakeEngineKind else { return }
        swapWakeEngine(to: desired)
    }

    /// Stop the current engine, instantiate `kind`, rebind callbacks, and
    /// re-arm if an episode was already loaded.
    @MainActor
    private func swapWakeEngine(to kind: WakeEngineKind) {
        let wasArmed = wakeArmed
        wake.onDetect = nil
        wake.onTranscript = nil
        wake.stop()
        wakeArmed = false
        wakeEngineKind = kind
        wake = Self.makeWakeEngine(kind: kind)
        bindWakeCallbacks()
        // Re-evaluate the armed condition against the (still-current)
        // live / voiceOpen / wakePaused state. updateWakeArmed is
        // idempotent and will start the new engine if appropriate.
        if wasArmed {
            updateWakeArmed()
        }
    }

    /// Reconcile MicCapture + WakeWordEngine to the current state.
    /// Idempotent. Called from any transition that changes `live` or
    /// `voiceOpen`.
    private func updateWakeArmed() {
        // Wake only listens when an episode is loaded. The dev tracking
        // toggle controls toast surfacing only — it does not force-arm
        // the engine, because firing wake without a loaded episode opens
        // an empty voice agent that the user has no context for.
        let shouldRunMic = live != nil && liveTranscriptReady
        let shouldArmWake = shouldRunMic && !voiceOpen && !wakePaused

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

    func openVoiceAgent(source: VoiceEntrySource = .micButton) {
        if let live, !live.transcriptReadyForVoice {
            Analytics.shared.track(
                "voice_session_blocked",
                properties: [
                    "reason": "transcript_pending",
                    "entry": source.rawValue,
                    "episode_id": live.serverEpisodeId,
                    "position_seconds": currentTime,
                ]
            )
            return
        }

        // Stamp the entry so closeVoiceAgent's PostHog event can break the
        // session down by wake-word vs mic-tap.
        voiceSessionStartedAt = Date()
        voiceSessionEntry = source
        voiceUtteranceCount = 0
        voiceToolCallCount = 0
        Analytics.shared.track(
            "voice_session_opened",
            properties: [
                "entry": source.rawValue,
                "episode_id": live?.serverEpisodeId,
                "position_seconds": currentTime,
            ]
        )

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
        // Mirror phase 1 into the Live Activity: shade fades in, controls dim.
        LiveActivityController.shared.updateVoiceMode(
            inVoiceMode: true,
            voiceMorphActive: false,
            elapsed: currentTime,
            playing: playing
        )
        startLiveActivityGlowSampler()

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
            LiveActivityController.shared.updateVoiceMode(
                inVoiceMode: true,
                voiceMorphActive: true,
                elapsed: self.currentTime,
                playing: self.playing
            )
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
        let durationMs: Int = voiceSessionStartedAt.map {
            Int(Date().timeIntervalSince($0) * 1000)
        } ?? 0
        Analytics.shared.track(
            "voice_session_closed",
            properties: [
                "entry": voiceSessionEntry?.rawValue,
                "duration_ms": durationMs,
                "utterance_count": voiceUtteranceCount,
                "tool_call_count": voiceToolCallCount,
                "trace_id": voiceSession?.traceId,
                "ended_by": "user",
            ]
        )
        voiceSessionStartedAt = nil
        voiceSessionEntry = nil

        // Tear the realtime session down first so it stops claiming the
        // mic / restores audio-session config before AudioPlayer resumes.
        voiceSession?.stop()
        voiceSession = nil

        // Phase 1 (reversed): waveform fades out. The shade and playback
        // details stay put during this phase.
        withAnimation(.easeInOut(duration: 0.25)) { voiceMorphActive = false }
        LiveActivityController.shared.updateVoiceMode(
            inVoiceMode: true,
            voiceMorphActive: false,
            elapsed: currentTime,
            playing: playing
        )
        stopLiveActivityGlowSampler()

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
            LiveActivityController.shared.updateVoiceMode(
                inVoiceMode: false,
                voiceMorphActive: false,
                elapsed: self.currentTime,
                playing: self.playing
            )
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

    // MARK: - Live Activity glow sampler
    //
    // Lock-screen Live Activities can't drive their own animation loop;
    // the only continuous-motion channel is to push a new ContentState
    // and let the system crossfade between snapshots. We sample
    // `voiceSession.inputLevel` and `outputLevel` at 5Hz, each gated by
    // the matching phase (mic only counts while listening, output only
    // counts while the assistant speaks). The two channels drive separate
    // glow surfaces in the LA: orb halo (user) and progress bar (assistant).
    private func startLiveActivityGlowSampler() {
        stopLiveActivityGlowSampler()
        // EXPERIMENT: timer interval matches LiveActivityController's
        // glowPushIntervalSec (currently 0.05 = 20Hz). Testing whether
        // high-rate Activity.update calls keep the lock screen awake.
        let interval = LiveActivityController.glowPushIntervalSec
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.voiceOpen else { return }
                let session = self.voiceSession
                let userLevel: Double = {
                    guard let session, session.phase == .listening else { return 0 }
                    return Double(session.inputLevel)
                }()
                // Assistant glow comes from the WebRTC inbound-rtp audio
                // level. Phase-gated to `.speaking` and noise-floored to
                // 0.02 (matches the in-app waveform's gating) so brief
                // hisses between turns don't trigger a glow.
                let assistantLevel: Double = {
                    guard let session,
                          session.phase == .speaking,
                          session.outputLevel > 0.02 else { return 0 }
                    return Double(session.outputLevel)
                }()
                // Phase-driven (not level-gated) so the bars stay up
                // through brief pauses within an assistant turn instead
                // of flickering back to the Listening indicator.
                let assistantSpeaking = (session?.phase == .speaking)
                LiveActivityController.shared.pushGlow(
                    userLevel: userLevel,
                    assistantLevel: assistantLevel,
                    assistantSpeaking: assistantSpeaking,
                    elapsed: self.currentTime,
                    playing: self.playing
                )
            }
        }
        liveActivityGlowTimer = timer
    }

    private func stopLiveActivityGlowSampler() {
        liveActivityGlowTimer?.invalidate()
        liveActivityGlowTimer = nil
    }

    /// AVPlayer's currentTime when live; falls back to the simulated
    /// time otherwise. Returns nil when neither is meaningful (no live
    /// episode loaded).
    private func currentPausedSeconds() -> Double? {
        if live != nil { return audio.currentTime }
        return nil
    }

    /// Called by RealtimeVoiceSession whenever a Whisper-completed user
    /// transcript lands. Bumps `voiceUtteranceCount` so the closing event has
    /// an accurate total, and fires `voice_first_utterance` exactly once per
    /// session.
    func recordVoiceUtterance(isFirst: Bool) {
        voiceUtteranceCount += 1
        guard isFirst, let started = voiceSessionStartedAt else { return }
        Analytics.shared.track(
            "voice_first_utterance",
            properties: [
                "trace_id": voiceSession?.traceId,
                "ms_to_first_utterance": Int(Date().timeIntervalSince(started) * 1000),
            ]
        )
    }

    /// Called by RealtimeTools whenever a tool fires. Bumps the per-session
    /// counter; the dispatched-event itself is emitted by the dispatcher so
    /// it can stamp tool-specific properties.
    func recordVoiceToolCall() {
        voiceToolCallCount += 1
    }

    func seek(_ t: Double, reason: String = "manual") {
        let from = currentTime
        let clamped = max(0, min(totalDuration, t))
        if live != nil {
            audio.seek(to: clamped)
            syncProgress(force: true)
        } else {
            currentTime = clamped
        }
        Analytics.shared.track(
            "playback_seeked",
            properties: [
                "episode_id": live?.serverEpisodeId,
                "from_s": from,
                "to_s": clamped,
                "reason": reason,
            ]
        )
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
        // Newly-fetched rows may have flipped processing→ready or removed
        // the last processing row entirely; re-evaluate the poll loop.
        updateLibraryPolling()
    }

    // MARK: - Library tab visibility / processing-row polling

    var hasProcessingLibraryRow: Bool {
        library.contains { $0.episode.status == .processing }
    }

    /// Called from LibraryView.onAppear. Triggers an immediate fetch (the
    /// existing tab-open refresh) and starts the 5s poll loop if needed.
    func libraryTabAppeared() {
        libraryTabVisible = true
        Task { await reloadLibrary() }
    }

    /// Called from LibraryView.onDisappear. Stops the poll loop — we
    /// don't want it firing every 5s while the user is on Listen / Notes.
    func libraryTabDisappeared() {
        libraryTabVisible = false
        updateLibraryPolling()
    }

    private func updateLibraryPolling() {
        let shouldPoll = libraryTabVisible && scenePhaseActive && hasProcessingLibraryRow
        if shouldPoll {
            guard libraryPollTimer == nil else { return }
            libraryPollTimer = Timer.publish(every: 5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.reloadLibrary()
                    }
                }
        } else {
            libraryPollTimer?.cancel()
            libraryPollTimer = nil
        }
    }

    /// Open an episode from the library immediately. Transcript indexing is a
    /// background concern; the player can render an indexing state until the
    /// cached or partial transcript arrives.
    func openFromLibrary(_ item: LibraryItem) async {
        // Article-derived rows aren't playable until the TTS worker
        // finishes; `audioUrl` is a synthetic `cue-tts://pending/<uuid>`
        // string that AVPlayer can't resolve. Bail out silently — the
        // library card already surfaces the processing/failed state, and
        // the row is no-tap by construction (see LibraryView).
        guard item.episode.status == .ready else {
            print("[Cue] openFromLibrary skipped — episode \(item.episode.id) status=\(item.episode.status.rawValue)")
            return
        }

        if isLive(episodeId: item.episode.id) {
            openPlayer()
            if !audio.isPlaying {
                audio.play()
                audio.setRate(Float(speed))
            }
            return
        }

        let show = ResolvedShow(
            title: item.episode.showTitle,
            author: item.episode.showAuthor,
            feedUrl: item.episode.showFeedUrl ?? "",
            artworkUrl: item.episode.showArtworkUrl,
            spotifyShowId: item.episode.spotifyShowId
        )
        let episode = ResolvedEpisode(
            title: item.episode.episodeTitle,
            audioUrl: item.episode.audioUrl,
            durationSeconds: item.episode.durationSeconds,
            pubDate: item.episode.episodePubDate,
            guid: item.episode.episodeGuid ?? "",
            description: item.episode.episodeDescription,
            artworkUrl: item.episode.episodeArtworkUrl ?? item.episode.showArtworkUrl,
            spotifyEpisodeId: item.episode.spotifyEpisodeId,
            spotifyShowId: item.episode.spotifyShowId
        )
        loadLive(
            LiveEpisode(
                show: show,
                episode: episode,
                transcript: Self.emptyTranscript(durationSeconds: item.episode.durationSeconds),
                serverEpisodeId: item.episode.id,
                transcriptReadyForVoice: false
            ),
            resumeAt: item.positionSeconds
        )
        startTranscriptIndexing(
            audioUrl: item.episode.audioUrl,
            durationSeconds: item.episode.durationSeconds
        )
        Task { await reloadLibrary() }
    }

    func startTranscriptIndexing(audioUrl: String, durationSeconds: Double?) {
        if transcriptIndexingTasks[audioUrl] != nil { return }

        updateTranscriptIndexingProgress(
            audioUrl: audioUrl,
            progress: TranscriptIndexingProgress(stage: "starting", completedCount: 0, chunkCount: nil)
        )

        let startedAt = Date()
        Analytics.shared.track(
            "podcast_transcribe_started",
            properties: ["audio_duration_s": durationSeconds]
        )

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.transcriptIndexingTasks[audioUrl] = nil }

            var partialChunks: [Int: TranscribeChunkResult] = [:]
            do {
                var finalTranscript: TranscribeResponse?
                for try await event in CueAPI.shared.transcribePodcastStream(
                    audioUrl: audioUrl,
                    durationSeconds: durationSeconds
                ) {
                    switch event {
                    case .status(let stage, let chunkCount, _, _):
                        let completed = self.liveTranscriptIndexingProgress?.completedCount ?? 0
                        self.updateTranscriptIndexingProgress(
                            audioUrl: audioUrl,
                            progress: TranscriptIndexingProgress(
                                stage: stage,
                                completedCount: completed,
                                chunkCount: chunkCount ?? self.liveTranscriptIndexingProgress?.chunkCount
                            )
                        )
                    case .chunkResult(let chunk):
                        partialChunks[chunk.chunkIndex] = chunk
                        self.updateTranscriptIndexingProgress(
                            audioUrl: audioUrl,
                            progress: TranscriptIndexingProgress(
                                stage: "transcribing",
                                completedCount: chunk.completedCount,
                                chunkCount: chunk.chunkCount
                            )
                        )
                        let partial = Self.partialTranscript(
                            from: partialChunks,
                            durationSeconds: durationSeconds
                        )
                        self.replaceLiveTranscript(
                            partial,
                            audioUrl: audioUrl,
                            transcriptReadyForVoice: false
                        )
                    case .result(let transcript):
                        finalTranscript = transcript
                        self.replaceLiveTranscript(
                            transcript,
                            audioUrl: audioUrl,
                            transcriptReadyForVoice: true
                        )
                    case .error(let message):
                        throw CueAPIError.server(status: 0, message: message)
                    case .chunkDone, .heartbeat:
                        break
                    }
                }

                guard let finalTranscript else {
                    throw CueAPIError.server(status: 0, message: "Transcription ended without a result.")
                }
                Analytics.shared.track(
                    "podcast_transcribe_completed",
                    properties: [
                        "ok": true,
                        "ms": Int(Date().timeIntervalSince(startedAt) * 1000),
                        "cached": finalTranscript.cached,
                        "segment_count": finalTranscript.segments.count,
                    ]
                )
                await self.reloadLibrary()
            } catch {
                self.updateTranscriptIndexingProgress(
                    audioUrl: audioUrl,
                    progress: TranscriptIndexingProgress(
                        stage: "failed",
                        completedCount: self.liveTranscriptIndexingProgress?.completedCount ?? 0,
                        chunkCount: self.liveTranscriptIndexingProgress?.chunkCount
                    )
                )
                Analytics.shared.track(
                    "podcast_transcribe_completed",
                    properties: [
                        "ok": false,
                        "ms": Int(Date().timeIntervalSince(startedAt) * 1000),
                        "error_message": error.localizedDescription,
                    ]
                )
                print("[Cue] transcript indexing failed: \(error)")
            }
        }
        transcriptIndexingTasks[audioUrl] = task
    }

    private func updateTranscriptIndexingProgress(
        audioUrl: String,
        progress: TranscriptIndexingProgress?
    ) {
        guard live?.episode.audioUrl == audioUrl else { return }
        liveTranscriptIndexingProgress = progress
    }

    static func emptyTranscript(durationSeconds: Double?) -> TranscribeResponse {
        TranscribeResponse(
            provider: "openai",
            text: "",
            words: [],
            segments: [],
            cached: false,
            durationSeconds: durationSeconds
        )
    }

    private static func partialTranscript(
        from chunks: [Int: TranscribeChunkResult],
        durationSeconds: Double?
    ) -> TranscribeResponse {
        var ordered: [TranscribeChunkResult] = []
        var idx = 0
        while let chunk = chunks[idx] {
            ordered.append(chunk)
            idx += 1
        }

        return TranscribeResponse(
            provider: "openai",
            text: ordered.map(\.text).filter { !$0.isEmpty }.joined(separator: " "),
            words: ordered.flatMap(\.words),
            segments: ordered.flatMap(\.segments),
            cached: false,
            durationSeconds: durationSeconds
        )
    }

    func removeFromLibrary(episodeId: Int) async {
        do {
            try await CueAPI.shared.removeFromLibrary(episodeId: episodeId)
            library.removeAll { $0.episode.id == episodeId }
        } catch {
            print("[Cue] remove from library: \(error)")
        }
    }

    // MARK: - Notes

    /// Refresh the flat Notes-tab list from the server.
    func reloadAllNotes() async {
        notesLoading = true
        defer { notesLoading = false }
        do {
            allNotes = try await CueAPI.shared.getAllNotes()
        } catch {
            print("[Cue] notes reload failed: \(error)")
        }
    }

    /// Load notes for the currently-playing episode so the scrubber can
    /// render markers. Called from `loadLive` whenever a new episode comes
    /// up.
    func reloadNotesForLiveEpisode(episodeId: Int) async {
        do {
            let notes = try await CueAPI.shared.getNotes(episodeId: episodeId)
            notesByEpisode[episodeId] = notes
        } catch {
            print("[Cue] per-episode notes reload failed: \(error)")
        }
    }

    /// Insert a freshly-saved note into both caches so the scrubber marker
    /// + Notes tab update without a refetch. Called from the `save_note`
    /// realtime tool dispatch on success.
    func appendNote(_ note: ServerNoteWithEpisode) {
        allNotes.insert(note, at: 0)
        let perEp = ServerNote(
            id: note.id,
            episodeId: note.episodeId,
            positionSeconds: note.positionSeconds,
            text: note.text,
            createdAt: note.createdAt
        )
        var existing = notesByEpisode[note.episodeId] ?? []
        existing.append(perEp)
        existing.sort { $0.positionSeconds < $1.positionSeconds }
        notesByEpisode[note.episodeId] = existing
    }

    func deleteNote(noteId: Int) async {
        // Optimistic remove — rollback on failure.
        let priorAll = allNotes
        let priorByEp = notesByEpisode
        allNotes.removeAll { $0.id == noteId }
        for (epId, list) in notesByEpisode {
            notesByEpisode[epId] = list.filter { $0.id != noteId }
        }
        do {
            try await CueAPI.shared.deleteNote(noteId: noteId)
        } catch {
            print("[Cue] delete note failed: \(error)")
            allNotes = priorAll
            notesByEpisode = priorByEp
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
        self.liveTranscriptIndexingProgress = live.transcriptReadyForVoice
            ? nil
            : TranscriptIndexingProgress(stage: "starting", completedCount: 0, chunkCount: nil)
        self.currentTime = resumeAt
        self.lastSyncedPosition = -1
        self.lastNowPlayingSecond = -1
        // Reset PostHog playback gates so the new episode gets a fresh
        // playback_started + playback_completed cycle.
        self.firstPlayFiredForLive = false
        self.completionFiredForLive = false
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
        if let episodeId = live.serverEpisodeId {
            Task { await self.reloadNotesForLiveEpisode(episodeId: episodeId) }
        }
        openPlayer()
    }

    /// Hydrate the currently-loaded episode with newer transcript data
    /// without touching the AVPlayer. Used by onboarding while transcription
    /// streams in behind already-started playback.
    func replaceLiveTranscript(
        _ transcript: TranscribeResponse,
        audioUrl: String,
        transcriptReadyForVoice: Bool = true
    ) {
        guard let current = live, current.episode.audioUrl == audioUrl else { return }
        live = LiveEpisode(
            show: current.show,
            episode: current.episode,
            transcript: transcript,
            serverEpisodeId: current.serverEpisodeId,
            transcriptReadyForVoice: transcriptReadyForVoice
        )
        if transcriptReadyForVoice {
            liveTranscriptIndexingProgress = nil
        }
        updateWakeArmed()
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
