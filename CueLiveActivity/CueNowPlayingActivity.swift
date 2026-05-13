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
        HStack(alignment: .top, spacing: 12) {
            Button(intent: PlayPauseIntent()) {
                PlayGlyph(playing: state.playing, diameter: 64, iconSize: 24)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 0) {
                // Show eyebrow — top edge aligns with top of play button.
                Text(attributes.show.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(LA.accent.opacity(0.9))
                    .shadow(color: LA.accentGlow.opacity(0.35), radius: 6)
                    .lineLimit(1)
                    .padding(.bottom, 9)

                // Episode title row — title center aligns with play button center.
                HStack(alignment: .center, spacing: 8) {
                    MarqueeText(
                        text: attributes.episode,
                        font: .system(size: 18, weight: .medium),
                        foreground: LA.textBright
                    )
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
                .padding(.bottom, 8)

                // Progress + remaining time on the right edge.
                HStack(alignment: .center, spacing: 8) {
                    ProgressBar(elapsed: state.elapsed, duration: attributes.duration)
                    Text(remainingLabel(state.elapsed, duration: attributes.duration))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(LA.textFuture)
                }
            }
        }
        .padding(14)
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

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LA.trackBase)
                Capsule()
                    .fill(LA.accent)
                    .frame(width: max(8, proxy.size.width * CGFloat(progress)))
                    .shadow(color: LA.accentGlow.opacity(0.45), radius: 6)
            }
        }
        .frame(height: 8)
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }
}

// MARK: - Marquee text

// Live Activities don't run animation loops the way apps do, so true 60fps
// marquee isn't possible. This uses TimelineView(.animation) which iOS will
// throttle to ~1Hz on the lock screen (smoother in the Dynamic Island). Only
// triggers for titles long enough that they'd be clipped at the default font.
private struct MarqueeText: View {
    let text: String
    let font: Font
    let foreground: Color

    private static let charLimit = 22

    var body: some View {
        if text.count > Self.charLimit {
            GeometryReader { proxy in
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let cycle: Double = 14.0
                    let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
                    let position = (1 - cos(phase * 2 * .pi)) / 2
                    let overflowChars = max(0, text.count - 16)
                    let maxScroll = CGFloat(overflowChars) * 8.5

                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(foreground)
                        .offset(x: -CGFloat(position) * maxScroll)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                        .clipped()
                }
            }
            .frame(height: 22)
        } else {
            Text(text)
                .font(font)
                .lineLimit(1)
                .foregroundStyle(foreground)
        }
    }
}
