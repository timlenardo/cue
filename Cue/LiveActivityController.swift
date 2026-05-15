import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Drives the system Live Activity (Dynamic Island + lock-screen card).
///
/// The activity's *attributes* (`CueActivityAttributes`) are defined in a
/// separate file that is shared with the Widget Extension target. The
/// widget target's `ActivityConfiguration` renders these views; this class
/// only handles the lifecycle (request/update/end) from the main app.
///
/// Until the Widget Extension target exists in the project, requesting an
/// activity will throw at runtime — callers catch and silently skip,
/// keeping the main app functional even before Layer 2 is wired.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    #if canImport(ActivityKit)
    private var activity: Activity<CueActivityAttributes>?
    #endif

    private var lastUpdateAt: Date?

    /// Mirror of `AppState.voiceOpen` / `voiceMorphActive`. Stored here so
    /// the throttled progress-tick pushes (`update`) preserve voice flags
    /// rather than clobbering them back to false on every second.
    private var inVoiceMode: Bool = false
    private var voiceMorphActive: Bool = false
    private var userGlowLevel: Double = 0
    private var assistantGlowLevel: Double = 0
    private var assistantSpeaking: Bool = false
    private var lastGlowPushAt: Date?

    // Push interval during voice mode. 0.2s = 5Hz, the rate where the
    // system reliably re-renders without throttling or smearing
    // consecutive snapshot crossfades into each other. Bumping this
    // higher (e.g. 0.05 / 20Hz) doesn't keep the lock screen awake
    // — Activity.update has no screen-wake side effect — and the
    // visible animation actually slows down because the system drops
    // pushes once the FrequentUpdates budget is hit.
    static let glowPushIntervalSec: Double = 0.2
    /// Monotonically-incrementing animation frame. Bumped by every push
    /// (pushGlow at 5Hz during voice mode, update at 1Hz during playback)
    /// so the widget can derive cycling animations from a single integer
    /// rather than each animated element keeping its own state.
    private var animationFrame: Int = 0

    /// Fired when the underlying Activity transitions to `.ended` /
    /// `.dismissed` (system tear-down, user swipe-away, budget exhaustion,
    /// or explicit `end()`). AppState wires this to stop its 5Hz glow
    /// sampler so the timer doesn't keep firing against a nil activity.
    /// Annotated `@MainActor` because subscribers (e.g. AppState) typically
    /// invoke MainActor-isolated methods from the callback.
    var onActivityEnded: (@MainActor () -> Void)?

    #if canImport(ActivityKit)
    /// Holds the long-running activityStateUpdates observer Task so we
    /// can cancel it when the activity ends or is replaced.
    private var stateObserverTask: Task<Void, Never>?
    #endif

    /// Whether a Live Activity is currently active. AppState's sampler
    /// reads this to avoid burning timer ticks when no activity exists.
    func hasActivity() -> Bool {
        #if canImport(ActivityKit)
        return activity != nil
        #else
        return false
        #endif
    }

    /// Begin a Live Activity for the currently playing episode. Replaces any
    /// existing activity so the most recent paste wins.
    func start(show: String, episode: String, duration: Double, elapsed: Double) {
        #if canImport(ActivityKit)
        Task { @MainActor in
            await endNow()

            let info = ActivityAuthorizationInfo()
            print("[Cue/LA] start called. enabled=\(info.areActivitiesEnabled) freq=\(info.frequentPushesEnabled) show='\(show)' ep='\(episode)' dur=\(duration) elapsed=\(elapsed)")
            guard info.areActivitiesEnabled else {
                print("[Cue/LA] aborting: areActivitiesEnabled == false")
                return
            }

            let attributes = CueActivityAttributes(show: show, episode: episode, duration: duration)
            let state = CueActivityAttributes.ContentState(elapsed: elapsed, playing: true)
            do {
                let act = try Activity.request(
                    attributes: attributes,
                    content: .init(state: state, staleDate: nil)
                )
                activity = act
                observeStateUpdates(for: act)
                print("[Cue/LA] activity started id=\(act.id) state=\(act.activityState)")
            } catch {
                print("[Cue/LA] start failed: \(error)")
            }
        }
        #endif
    }

    /// Push elapsed + playing into the running activity. Throttled to ~1s so
    /// we don't hammer ActivityKit.
    func update(elapsed: Double, playing: Bool, duration: Double) {
        #if canImport(ActivityKit)
        guard let activity else { return }
        let now = Date()
        if let last = lastUpdateAt, now.timeIntervalSince(last) < 1.0 { return }
        lastUpdateAt = now
        animationFrame &+= 1

        let state = CueActivityAttributes.ContentState(
            elapsed: elapsed,
            playing: playing,
            inVoiceMode: inVoiceMode,
            voiceMorphActive: voiceMorphActive,
            userGlowLevel: userGlowLevel,
            assistantGlowLevel: assistantGlowLevel,
            assistantSpeaking: assistantSpeaking,
            animationFrame: animationFrame
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
        #endif
    }

    /// Push a voice-mode flag transition. Bypasses the 1s throttle since the
    /// caller is driving the shade / orb / waveform transition in real time
    /// (mirrors `AppState.openVoiceAgent` / `closeVoiceAgent`).
    func updateVoiceMode(
        inVoiceMode: Bool,
        voiceMorphActive: Bool,
        elapsed: Double,
        playing: Bool
    ) {
        #if canImport(ActivityKit)
        // Reset glow on the leading edge of voice mode so the orb / bar
        // don't appear at the previous session's last amplitude.
        if inVoiceMode && !self.inVoiceMode {
            userGlowLevel = 0
            assistantGlowLevel = 0
        }
        self.inVoiceMode = inVoiceMode
        self.voiceMorphActive = voiceMorphActive

        guard let activity else { return }
        lastUpdateAt = Date()
        animationFrame &+= 1

        let state = CueActivityAttributes.ContentState(
            elapsed: elapsed,
            playing: playing,
            inVoiceMode: inVoiceMode,
            voiceMorphActive: voiceMorphActive,
            userGlowLevel: userGlowLevel,
            assistantGlowLevel: assistantGlowLevel,
            assistantSpeaking: assistantSpeaking,
            animationFrame: animationFrame
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
        #endif
    }

    /// Push mic + assistant amplitudes into the running activity.
    /// Throttled to 200ms (5Hz). Delta gate triggers if either channel
    /// changed meaningfully — quiet stretches on both channels are dropped.
    /// Caller is expected to have already phase-gated each level (zero out
    /// the user channel when assistant is speaking and vice versa).
    func pushGlow(
        userLevel: Double,
        assistantLevel: Double,
        assistantSpeaking: Bool,
        elapsed: Double,
        playing: Bool
    ) {
        #if canImport(ActivityKit)
        guard inVoiceMode else { return }
        let u = min(1, max(0, userLevel))
        let a = min(1, max(0, assistantLevel))
        // Delta gate disabled while the widget needs every push to
        // advance `animationFrame` (silent stretches still need frame
        // ticks for the dots / bars to keep cycling). 200ms throttle
        // below is enough to bound budget consumption.

        let now = Date()
        if let last = lastGlowPushAt, now.timeIntervalSince(last) < Self.glowPushIntervalSec { return }
        lastGlowPushAt = now
        lastUpdateAt = now
        userGlowLevel = u
        assistantGlowLevel = a
        self.assistantSpeaking = assistantSpeaking
        animationFrame &+= 1

        guard let activity else { return }
        let state = CueActivityAttributes.ContentState(
            elapsed: elapsed,
            playing: playing,
            inVoiceMode: inVoiceMode,
            voiceMorphActive: voiceMorphActive,
            userGlowLevel: u,
            assistantGlowLevel: a,
            assistantSpeaking: assistantSpeaking,
            animationFrame: animationFrame
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
        #endif
    }

    /// End the activity (e.g. player closed, episode finished, app quit).
    func end() {
        #if canImport(ActivityKit)
        Task { @MainActor in await endNow() }
        #endif
    }

    #if canImport(ActivityKit)
    private func endNow() async {
        stateObserverTask?.cancel()
        stateObserverTask = nil
        let hadActivity = activity != nil
        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        // Reset voice state so the next activity doesn't inherit stale
        // flags / glow levels from the prior session.
        resetVoiceState()
        // Fire the lifecycle callback so subscribers (AppState's sampler)
        // stop work even when end was triggered explicitly rather than by
        // the system tearing the activity down.
        if hadActivity { onActivityEnded?() }
    }

    /// Observe ActivityKit lifecycle so we notice external dismissals
    /// (system tear-down, user swipe-away, budget exhaustion). Without
    /// this, AppState's 5Hz sampler keeps firing against a dead activity.
    /// The enclosing class is @MainActor, so the Task inherits isolation.
    private func observeStateUpdates(for activity: Activity<CueActivityAttributes>) {
        stateObserverTask?.cancel()
        stateObserverTask = Task { @MainActor [weak self] in
            for await stateUpdate in activity.activityStateUpdates {
                guard let self else { return }
                if stateUpdate == .ended || stateUpdate == .dismissed {
                    print("[Cue/LA] activity ended externally state=\(stateUpdate)")
                    self.activity = nil
                    self.resetVoiceState()
                    self.onActivityEnded?()
                    return
                }
            }
        }
    }

    private func resetVoiceState() {
        inVoiceMode = false
        voiceMorphActive = false
        userGlowLevel = 0
        assistantGlowLevel = 0
        assistantSpeaking = false
        lastGlowPushAt = nil
        animationFrame = 0
    }
    #endif
}
