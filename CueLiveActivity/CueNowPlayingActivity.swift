import ActivityKit
import AppIntents
import WidgetKit
import SwiftUI

// Mirror of the main app's `Ambient` palette. Hardcoded here because
// Tokens.swift lives in the Cue target only; if Ambient ever changes,
// update these too.
private enum LA {
    static let accent      = Color(red: 168/255, green: 213/255, blue: 186/255)  // #A8D5BA sage
    static let accentGlow  = Color(red: 168/255, green: 213/255, blue: 186/255)
    static let bg          = Color(red:  10/255, green:   9/255, blue:   8/255)  // #0A0908
    static let trackBase   = Color(red:  39/255, green:  39/255, blue:  42/255)  // #27272A
    static let textBright  = Color(red: 253/255, green: 252/255, blue: 251/255)  // #FDFCFB
    static let textPrimary = Color(red: 226/255, green: 232/255, blue: 240/255)  // #E2E8F0
    static let textFuture  = Color(red: 161/255, green: 161/255, blue: 170/255)  // #A1A1AA
}

/// Lock-screen card + Dynamic Island (compact / minimal / expanded) for the
/// currently playing Cue podcast episode.
struct CueNowPlayingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CueActivityAttributes.self) { context in
            LockScreenView(
                attributes: context.attributes,
                state: context.state
            )
            .activityBackgroundTint(LA.bg)
            .activitySystemActionForegroundColor(LA.textBright)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PlayGlyph(playing: context.state.playing, diameter: 32, iconSize: 12)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(remainingLabel(context.state.elapsed, duration: context.attributes.duration))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(LA.textFuture)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.show.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(LA.accent.opacity(0.9))
                            .shadow(color: LA.accentGlow.opacity(0.35), radius: 6)
                            .lineLimit(1)
                        Text(context.attributes.episode)
                            .font(.system(size: 14, weight: .medium))
                            .tracking(0.2)
                            .foregroundStyle(LA.textBright)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressBar(
                        elapsed: context.state.elapsed,
                        duration: context.attributes.duration
                    )
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LA.accent)
            } compactTrailing: {
                Text(remainingLabel(context.state.elapsed, duration: context.attributes.duration))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(LA.textBright)
            } minimal: {
                Image(systemName: context.state.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LA.accent)
            }
            .widgetURL(URL(string: "cue://now-playing"))
        }
    }

}

private func remainingLabel(_ elapsed: Double, duration: Double) -> String {
    let remaining = max(0, duration - elapsed)
    let m = Int(remaining) / 60
    let s = Int(remaining) % 60
    if m >= 60 {
        let h = m / 60
        return String(format: "%d:%02d:%02d", h, m % 60, s)
    }
    return String(format: "%d:%02d", m, s)
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let attributes: CueActivityAttributes
    let state: CueActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Play button slot — orb during voice mode (after morph delay),
            // plain play/pause otherwise. Same 64pt footprint in both states
            // so the structural swap doesn't shift the row.
            ZStack {
                if state.voiceMorphActive {
                    VoiceOrbGlyph(diameter: 64, glowLevel: state.userGlowLevel)
                        .transition(.opacity)
                } else {
                    Button(intent: PlayPauseIntent()) {
                        PlayGlyph(playing: state.playing, diameter: 64, iconSize: 24)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .frame(width: 64, height: 64)
            .animation(.easeInOut(duration: 0.25), value: state.voiceMorphActive)

            // Right side — two completely different layouts based on voice
            // mode. Outside voice mode: eyebrow / title / progress stack
            // (no skip buttons — Now Playing widget already provides those).
            // Inside voice mode: a single centered indicator (Listening dots
            // or assistant bars), with a Resume button on the far right.
            if state.inVoiceMode {
                voiceModeContent
            } else {
                playbackContent
            }
        }
        .padding(14)
        .animation(.easeInOut(duration: 0.25), value: state.inVoiceMode)
    }

    // MARK: Non-voice layout (simplified — single invitation line)

    @ViewBuilder
    private var playbackContent: some View {
        Text("Tap or say Orbit")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(LA.textBright)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 64)
    }

    // MARK: Voice layout (Listening / bars centered, Resume on the right)

    @ViewBuilder
    private var voiceModeContent: some View {
        HStack(alignment: .center, spacing: 10) {
            // Indicator slot — left-aligned so "Listening…" sits just to the
            // right of the orb, with the bar visualizer occupying the same
            // slot when the assistant takes its turn. ZStack with opacity
            // crossfades keeps the play-button and resume-button positions
            // stable while the indicator swaps.
            ZStack(alignment: .leading) {
                ListeningIndicator(frame: state.animationFrame)
                    .opacity(state.assistantSpeaking ? 0 : 1)
                AssistantVisualizerRow(frame: state.animationFrame)
                    .opacity(state.assistantSpeaking ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.25), value: state.assistantSpeaking)

            ResumeButton()
        }
        .frame(height: 64)
    }
}

// MARK: - Resume button (voice mode)

/// Pill button shown on the right edge of the LA during voice mode.
/// Tapping invokes `CloseVoiceAgentIntent`, which posts the
/// `cueCloseVoiceAgent` notification and resumes podcast playback.
private struct ResumeButton: View {
    var body: some View {
        Button(intent: CloseVoiceAgentIntent()) {
            Text("Resume")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(LA.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        Capsule().fill(Color.black)
                        Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Voice-state indicators
//
// Continuous animation channel on the lock-screen LA: pushed `ContentState`
// changes. SF Symbol `.symbolEffect(.variableColor, .repeating)` is
// recognized by SwiftUI but does NOT loop independently in the widget
// snapshot model — the system only re-renders when state changes.
// So both indicators derive their motion from `state.animationFrame`,
// which the app increments on every push. The system crossfades between
// consecutive snapshots, which is what makes the dots / bars appear to
// animate. Frame ticks at 5Hz while voice mode is open (pushGlow) and
// 1Hz during playback (update).

/// "Listening…" with three dots that cycle one-at-a-time. The dots use
/// `.lastTextBaseline` alignment so their bottoms sit at the text's
/// baseline — punctuation-like positioning rather than vertically
/// centered with the cap-height.
private struct ListeningIndicator: View {
    let frame: Int

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text("Listening")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LA.accent)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    let active = i == (frame % 3)
                    Circle()
                        .fill(LA.accent)
                        .frame(width: 4, height: 4)
                        .opacity(active ? 1.0 : 0.25)
                        .scaleEffect(active ? 1.2 : 0.8, anchor: .bottom)
                }
            }
        }
        .shadow(color: LA.accentGlow.opacity(0.5), radius: 6)
        .accessibilityLabel("Listening")
    }
}

/// Row of 5 five-bar visualizers — 25 bars total — with per-group frame
/// offsets so the wave reads as continuous across all of them rather
/// than 5 identical units pulsing in sync.
private struct AssistantVisualizerRow: View {
    let frame: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                // 8-frame offset per group = 5 bars × spatialMultiplier 1.6
                // ÷ temporalMultiplier 1.0, so the wave flows continuously
                // from group N into group N+1 without a seam.
                AssistantVisualizer(frame: frame &+ i * 8)
            }
        }
        .accessibilityLabel("Assistant speaking")
    }
}

/// Five-bar audio visualizer. Each bar's height is a phase-shifted sin
/// of `animationFrame`. The system crossfades the heights between pushes,
/// so the bars appear to ripple. Pure pushed-state animation — no
/// dependence on `.symbolEffect`, which doesn't loop in widget contexts.
private struct AssistantVisualizer: View {
    let frame: Int

    private static let barCount = 5
    private static let baseHeight: CGFloat = 4
    private static let maxHeight: CGFloat = 22
    private static let barWidth: CGFloat = 3
    /// Temporal multiplier: how fast phase advances per pushed frame.
    /// At 5Hz pushes, 1.0 gives a ~1.25s full cycle per bar.
    private static let temporalMultiplier: Double = 1.0
    /// Spatial multiplier: phase offset between adjacent bars. Higher
    /// values make the bars look like a steeper wave (more height
    /// variation across neighbors). 1.6 matches the playground's
    /// "Heartbeat" preset.
    private static let spatialMultiplier: Double = 1.6

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                Capsule()
                    .fill(LA.accent)
                    .frame(width: Self.barWidth, height: height(forBar: i))
            }
        }
        .frame(height: Self.maxHeight, alignment: .center)
        .shadow(color: LA.accentGlow.opacity(0.55), radius: 6)
    }

    private func height(forBar i: Int) -> CGFloat {
        let phase = Double(frame) * Self.temporalMultiplier + Double(i) * Self.spatialMultiplier
        let n = (sin(phase) + 1) / 2  // 0…1
        return Self.baseHeight + (Self.maxHeight - Self.baseHeight) * CGFloat(n)
    }
}

// MARK: - Voice mode glyphs
//
// Lock-screen Live Activities can't drive their own per-frame animation
// loop — `TimelineView(.animation)`, `withAnimation`, and `.animation(value:)`
// are all ignored or throttled to a static snapshot per Apple's docs. The
// only continuous motion channel is to push a new `ContentState` from the
// app and let the system crossfade between snapshots. The orb halo's level
// is the upstream-gated user amplitude — zero when the assistant is
// speaking, so the orb reads as "muted and minimal" during AI turns.

private struct VoiceOrbGlyph: View {
    let diameter: CGFloat
    /// 0…1 mic amplitude pushed from the app. Already phase-gated upstream
    /// to `phase == .listening`, so it reads zero whenever the assistant
    /// is speaking — the halo collapses to its base "minimal" appearance.
    let glowLevel: Double

    var body: some View {
        ZStack {
            // Sage-green halo. Base of 0.10 means the orb is barely
            // haloed when the user isn't talking, then ramps to ~0.95
            // on a loud peak. Same ramp on scale.
            Circle()
                .fill(LA.accent)
                .frame(width: diameter * 1.6, height: diameter * 1.6)
                .blur(radius: 18)
                .opacity(0.10 + glowLevel * 0.85)
                .scaleEffect(1.0 + CGFloat(glowLevel) * 0.22)

            // White core — gently scales with amplitude so the whole orb
            // breathes together rather than the halo floating on a flat disc.
            Circle()
                .fill(LA.textPrimary)
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                .frame(width: diameter, height: diameter)
                .scaleEffect(1.0 + CGFloat(glowLevel) * 0.10)
                .shadow(color: .white.opacity(0.15 + glowLevel * 0.55), radius: 10 + glowLevel * 14)
        }
    }
}

// MARK: - Play button (mirror of PlayerView.PlayButton, scaled for widget)

private struct PlayGlyph: View {
    let playing: Bool
    let diameter: CGFloat
    let iconSize: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(LA.textPrimary)
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .white.opacity(0.10), radius: 8)
                .frame(width: diameter, height: diameter)
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(LA.bg)
        }
    }
}

// MARK: - Progress

private struct ProgressBar: View {
    let elapsed: Double
    let duration: Double
    /// nil → static glow (outside voice mode). Non-nil → in voice mode,
    /// the bar fills 100%, and a blurred sage halo capsule behind it
    /// reacts to this amplitude (0…1). Mirrors the orb's halo+core
    /// construction so the bloom reads at similar strength.
    var dynamicGlow: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = max(8, proxy.size.width * CGFloat(progress))
            ZStack(alignment: .leading) {
                // Track.
                Capsule()
                    .fill(LA.trackBase)

                // Halo: blurred sage capsule, fully proportional to the
                // assistant level so it disappears entirely between turns.
                if let g = dynamicGlow, g > 0 {
                    Capsule()
                        .fill(LA.accent)
                        .frame(width: fillWidth)
                        .scaleEffect(y: 1.5 + CGFloat(g) * 2.5)
                        .blur(radius: 4 + CGFloat(g) * 6)
                        .opacity(g * 1.15)
                }

                // Solid fill.
                Capsule()
                    .fill(LA.accent)
                    .frame(width: fillWidth)
                    .shadow(color: LA.accentGlow.opacity(coreShadowOpacity), radius: coreShadowRadius)
            }
        }
        .frame(height: 8)
    }

    private var progress: Double {
        // Full bar in voice mode (regardless of elapsed/duration).
        if dynamicGlow != nil { return 1 }
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    // Shadow on the SOLID fill — outside voice mode, the original static
    // glow. In voice mode, fully proportional (no base) so the bar reads
    // as a flat green capsule when the assistant is silent.
    private var coreShadowOpacity: Double {
        guard let g = dynamicGlow else { return 0.45 }
        return g * 0.70
    }

    private var coreShadowRadius: CGFloat {
        guard let g = dynamicGlow else { return 6 }
        return CGFloat(g) * 14
    }
}

