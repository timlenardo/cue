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

    /// Begin a Live Activity for the currently playing episode. Replaces any
    /// existing activity so the most recent paste wins.
    func start(show: String, episode: String, duration: Double, elapsed: Double) {
        #if canImport(ActivityKit)
        // Replace any existing activity first.
        Task { @MainActor in await endNow() }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = CueActivityAttributes(show: show, episode: episode, duration: duration)
        let state = CueActivityAttributes.ContentState(elapsed: elapsed, playing: true)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            // Most common cause: Widget Extension target not yet added.
            print("[Cue] Live Activity start failed: \(error)")
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

        let state = CueActivityAttributes.ContentState(elapsed: elapsed, playing: playing)
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
