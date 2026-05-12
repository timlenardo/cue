import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Shared between the main Cue target and the CueLiveActivity widget extension.
///
/// `attributes` are fixed for the lifetime of the activity (set at start).
/// `ContentState` is what we push on every update — elapsed time + playing.
struct CueActivityAttributes: ActivityAttributes {
    public typealias CueLiveActivityState = ContentState

    public struct ContentState: Codable, Hashable {
        public var elapsed: Double
        public var playing: Bool

        public init(elapsed: Double, playing: Bool) {
            self.elapsed = elapsed
            self.playing = playing
        }
    }

    public let show: String
    public let episode: String
    public let duration: Double

    public init(show: String, episode: String, duration: Double) {
        self.show = show
        self.episode = episode
        self.duration = duration
    }
}
#endif
