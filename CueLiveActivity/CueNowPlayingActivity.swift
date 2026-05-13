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
        let inVoice = state.inVoiceMode
        let morph   = state.voiceMorphActive

        HStack(alignment: .top, spacing: 12) {
            // Play button → orb. Swap fires on `voiceMorphActive` (phase 2)
            // so the structural swap lands after the surrounding controls
            // have finished dimming — same staging as PlayerView.
            ZStack {
                if morph {
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
            .animation(.easeInOut(duration: 0.25), value: morph)

            // Right column sized to match the play button (64pt) so the
            // bar's bottom aligns with the play button's bottom and the
            // title's vertical center aligns with the play button's center.
            VStack(alignment: .leading, spacing: 0) {
                // Show eyebrow — top of the column.
                Text(attributes.show.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(LA.accent.opacity(0.9))
                    .shadow(color: LA.accentGlow.opacity(0.35), radius: 6)
                    .lineLimit(1)
                    .opacity(inVoice ? 0.15 : 1)

                Spacer(minLength: 0)

                // Episode title + skip buttons — centered vertically in the
                // column (= play button center). Static text, default tail
                // truncation; no marquee.
                HStack(alignment: .center, spacing: 8) {
                    Text(attributes.episode)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(LA.textBright)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(intent: Skip15BackIntent()) {
                        SkipGlyph(systemName: "gobackward.15")
                    }
                    .buttonStyle(.plain)

                    Button(intent: Skip15ForwardIntent()) {
                        SkipGlyph(systemName: "goforward.15")
                    }
                    .buttonStyle(.plain)
                }
                .opacity(inVoice ? 0.15 : 1)
                .allowsHitTesting(!inVoice)

                Spacer(minLength: 0)

                // Progress + remaining time — bottom of the column, so the
                // bar's bottom edge lines up with the play button's bottom.
                HStack(alignment: .center, spacing: 8) {
                    ProgressBar(
                        elapsed: state.elapsed,
                        duration: attributes.duration,
                        dynamicGlow: inVoice ? state.assistantGlowLevel : nil
                    )
                    Text(remainingLabel(state.elapsed, duration: attributes.duration))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(LA.textFuture)
                        .opacity(inVoice ? 0.15 : 1)
                }
            }
            .frame(height: 64)
        }
        .padding(14)
        .animation(.easeInOut(duration: 0.25), value: inVoice)
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

// MARK: - Transport buttons

private struct SkipGlyph: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(LA.textBright.opacity(0.85))
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
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

