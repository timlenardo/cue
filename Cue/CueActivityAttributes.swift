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
        /// True while `voiceSession.phase == .speaking` — i.e. the assistant
        /// is on its turn. Stable across brief silent moments WITHIN the
        /// turn (unlike `assistantGlowLevel`, which drops to zero on
        /// pauses). Drives the LA's choice between Listening text vs bars.
        public var assistantSpeaking: Bool
        /// Monotonically incrementing frame counter, advanced by the app
        /// on every push. The widget uses it to derive cycling animations
        /// (typing-dot indicator, bar visualizer) — since lock-screen LAs
        /// don't support continuous in-widget animation loops, the
        /// app-pushed counter + system snapshot crossfade is the only
        /// channel that produces visible motion.
        public var animationFrame: Int

        public init(
            elapsed: Double,
            playing: Bool,
            inVoiceMode: Bool = false,
            voiceMorphActive: Bool = false,
            userGlowLevel: Double = 0,
            assistantGlowLevel: Double = 0,
            assistantSpeaking: Bool = false,
            animationFrame: Int = 0
        ) {
            self.elapsed = elapsed
            self.playing = playing
            self.inVoiceMode = inVoiceMode
            self.voiceMorphActive = voiceMorphActive
            self.userGlowLevel = userGlowLevel
            self.assistantGlowLevel = assistantGlowLevel
            self.assistantSpeaking = assistantSpeaking
            self.animationFrame = animationFrame
        }

        // Custom decoder so an in-flight Live Activity encoded by a
        // previous app version (only elapsed + playing) doesn't fail to
        // decode after upgrade. Swift's synthesized Decodable doesn't
        // honor init defaults for missing keys; `decodeIfPresent` does.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            elapsed = try c.decode(Double.self, forKey: .elapsed)
            playing = try c.decode(Bool.self, forKey: .playing)
            inVoiceMode = try c.decodeIfPresent(Bool.self, forKey: .inVoiceMode) ?? false
            voiceMorphActive = try c.decodeIfPresent(Bool.self, forKey: .voiceMorphActive) ?? false
            userGlowLevel = try c.decodeIfPresent(Double.self, forKey: .userGlowLevel) ?? 0
            assistantGlowLevel = try c.decodeIfPresent(Double.self, forKey: .assistantGlowLevel) ?? 0
            assistantSpeaking = try c.decodeIfPresent(Bool.self, forKey: .assistantSpeaking) ?? false
            animationFrame = try c.decodeIfPresent(Int.self, forKey: .animationFrame) ?? 0
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
