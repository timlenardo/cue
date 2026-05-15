import AppIntents
import Foundation

extension Notification.Name {
    static let cuePlayPause       = Notification.Name("CuePlayPauseIntent")
    static let cueSkip15Back      = Notification.Name("CueSkip15BackIntent")
    static let cueSkip15Forward   = Notification.Name("CueSkip15ForwardIntent")
    static let cueCloseVoiceAgent = Notification.Name("CueCloseVoiceAgentIntent")
}

// AudioPlaybackIntent: when a Live Activity button uses this, iOS runs
// `perform()` in the foreground host-app process. We post a notification
// instead of touching AppState directly so this file compiles cleanly in
// both the app and the widget extension targets.

struct PlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play / Pause"
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .cuePlayPause, object: nil)
        }
        return .result()
    }
}

struct Skip15BackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Back 15 Seconds"
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .cueSkip15Back, object: nil)
        }
        return .result()
    }
}

struct Skip15ForwardIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Forward 15 Seconds"
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .cueSkip15Forward, object: nil)
        }
        return .result()
    }
}

/// Tapped from the Live Activity's Resume button while voice mode is
/// open. Tears the realtime session down and resumes podcast playback —
/// `AppState.closeVoiceAgent()` does the heavy lifting via notification.
struct CloseVoiceAgentIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Resume Podcast"
    init() {}
    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .cueCloseVoiceAgent, object: nil)
        }
        return .result()
    }
}
