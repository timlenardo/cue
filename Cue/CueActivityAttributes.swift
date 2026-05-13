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
        /// Flips first when entering voice mode. Drives the "shade" — dims
        /// the eyebrow / title / time row so they read as covered.
        public var inVoiceMode: Bool
        /// Flips ~270ms after `inVoiceMode` so the structural swaps
        /// (play→orb, progress→waveform) happen after the dim has landed.
        /// Mirrors `AppState.voiceMorphActive` in the in-app player.
        public var voiceMorphActive: Bool
        /// Mic input amplitude (0…1), gated to `phase == .listening` upstream
        /// so it reads zero whenever the assistant is speaking. Drives the
        /// white orb halo's opacity / scale / shadow radius.
        public var userGlowLevel: Double
        /// Realtime session output amplitude (0…1), gated to `phase == .speaking`
        /// upstream. Drives the green progress-bar shadow's opacity / radius
        /// so the bar "lights up" while the assistant is talking.
        public var assistantGlowLevel: Double

        public init(
            elapsed: Double,
            playing: Bool,
            inVoiceMode: Bool = false,
            voiceMorphActive: Bool = false,
            userGlowLevel: Double = 0,
            assistantGlowLevel: Double = 0
        ) {
            self.elapsed = elapsed
            self.playing = playing
            self.inVoiceMode = inVoiceMode
            self.voiceMorphActive = voiceMorphActive
            self.userGlowLevel = userGlowLevel
            self.assistantGlowLevel = assistantGlowLevel
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
