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
    private var lastGlowPushAt: Date?

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

        let state = CueActivityAttributes.ContentState(
            elapsed: elapsed,
            playing: playing,
            inVoiceMode: inVoiceMode,
            voiceMorphActive: voiceMorphActive,
            userGlowLevel: userGlowLevel,
            assistantGlowLevel: assistantGlowLevel
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

        let state = CueActivityAttributes.ContentState(
            elapsed: elapsed,
            playing: playing,
            inVoiceMode: inVoiceMode,
            voiceMorphActive: voiceMorphActive,
            userGlowLevel: userGlowLevel,
            assistantGlowLevel: assistantGlowLevel
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
        #endif
    }

    /// Push mic + assistant amplitudes into the running activity.
    /// Throttled to 200ms (5Hz). Delta gate triggers if either channel
    /// changed meaningfully — quiet stretches on both channels are dropped.
    /// Caller is expected to have already phase-gated each level (zero out
    /// the user channel when assistant is speaking and vice versa).
    func pushGlow(userLevel: Double, assistantLevel: Double, elapsed: Double, playing: Bool) {
        #if canImport(ActivityKit)
        guard inVoiceMode else { return }
        let u = min(1, max(0, userLevel))
        let a = min(1, max(0, assistantLevel))
        // Relaxed delta gate while we're characterizing animation continuity.
        let userDelta = abs(u - userGlowLevel)
        let assistDelta = abs(a - assistantGlowLevel)
        if max(userDelta, assistDelta) < 0.005 { return }

        let now = Date()
        if let last = lastGlowPushAt, now.timeIntervalSince(last) < 0.2 { return }
        lastGlowPushAt = now
        lastUpdateAt = now
        userGlowLevel = u
        assistantGlowLevel = a

        guard let activity else { return }
        let state = CueActivityAttributes.ContentState(
            elapsed: elapsed,
            playing: playing,
            inVoiceMode: inVoiceMode,
            voiceMorphActive: voiceMorphActive,
            userGlowLevel: u,
            assistantGlowLevel: a
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
        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }
    #endif
}
