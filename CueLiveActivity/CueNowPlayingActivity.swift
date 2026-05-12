import ActivityKit
import WidgetKit
import SwiftUI

/// Lock-screen card + Dynamic Island (compact / minimal / expanded) for the
/// currently playing Cue podcast episode.
struct CueNowPlayingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CueActivityAttributes.self) { context in
            // Lock-screen / notification banner.
            LockScreenView(
                attributes: context.attributes,
                state: context.state
            )
            .activityBackgroundTint(Color.black.opacity(0.4))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color(red: 201/255, green: 84/255, blue: 58/255))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(remainingLabel(context.state.elapsed, duration: context.attributes.duration))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.attributes.show.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Text(context.attributes.episode)
                            .font(.system(size: 14, weight: .medium, design: .serif))
                            .foregroundStyle(.white)
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
                Image(systemName: context.state.playing ? "waveform" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 201/255, green: 84/255, blue: 58/255))
            } compactTrailing: {
                Text(remainingLabel(context.state.elapsed, duration: context.attributes.duration))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.playing ? "waveform" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 201/255, green: 84/255, blue: 58/255))
            }
            .widgetURL(URL(string: "cue://now-playing"))
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
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let attributes: CueActivityAttributes
    let state: CueActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            // Monogram — matches the in-app library tile aesthetic.
            ZStack {
                LinearGradient(
                    colors: [Color(red: 31/255, green: 42/255, blue: 58/255), Color(red: 31/255, green: 42/255, blue: 58/255).opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Text(monogram(attributes.show))
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(attributes.show.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(attributes.episode)
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                ProgressBar(elapsed: state.elapsed, duration: attributes.duration)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: state.playing ? "waveform" : "pause.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 201/255, green: 84/255, blue: 58/255))
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .padding(14)
    }

    private func monogram(_ s: String) -> String {
        let words = s
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        if let first = words.first?.first {
            if words.count >= 2, let second = words.dropFirst().first?.first {
                return "\(first)\(second)".uppercased()
            }
            return "\(first)".uppercased()
        }
        return "?"
    }
}

// MARK: - Progress

private struct ProgressBar: View {
    let elapsed: Double
    let duration: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(Color(red: 201/255, green: 84/255, blue: 58/255))
                    .frame(width: proxy.size.width * CGFloat(progress))
            }
        }
        .frame(height: 3)
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }
}
