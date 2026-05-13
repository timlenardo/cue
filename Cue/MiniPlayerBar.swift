import SwiftUI

/// Persistent now-playing bar shown above the tab bar whenever an episode
/// is loaded and the full player sheet isn't open. Modeled after Spotify's
/// mini player: tap the card to expand, tap the trailing button to toggle
/// play/pause.
struct MiniPlayerBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        guard let live = state.live else { return AnyView(EmptyView()) }
        let palette = state.palette
        let episode = live.episode
        let show = live.show
        let progress: Double = {
            let dur = state.totalDuration
            guard dur > 0 else { return 0 }
            return min(1, max(0, state.currentTime / dur))
        }()

        let bar = HStack(spacing: 10) {
            MiniMonogram(text: show.title, size: 36, radius: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(episode.title)
                    .font(Fonts.sans(13, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(show.title)
                    .font(Fonts.sans(11))
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { state.openPlayer() }

            Button {
                state.togglePlay()
            } label: {
                Image(systemName: state.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: Geo.miniPlayerHeight - 8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette.surface)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.cardEdge, lineWidth: 0.5)
            }
        )
        .overlay(alignment: .bottom) {
            // Thin progress strip along the bottom edge, like Spotify.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.subtleStrong)
                    Capsule().fill(palette.accent)
                        .frame(width: proxy.size.width * CGFloat(progress))
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        .padding(.horizontal, 8)

        return AnyView(bar)
    }
}

/// Mini monogram tile, deterministic color from the show title.
/// (Stripped-down copy of LibraryView's ShowMonogram — kept here so the
/// MiniPlayerBar has no cross-file dependency.)
private struct MiniMonogram: View {
    let text: String
    let size: CGFloat
    let radius: CGFloat

    // Computed once at struct init — body reads cached values directly.
    // The parent's body runs at 10 Hz (it reads `currentTime` for the
    // progress strip), so without caching the FNV-1a hash + token split
    // ran ~10×/sec. Realistic 1 µs/op × 10 → 10 µs/sec; not visible alone
    // but multiplies across mini bar + library rows.
    private let monogram: String
    private let color: Color

    init(text: String, size: CGFloat, radius: CGFloat) {
        self.text = text
        self.size = size
        self.radius = radius
        self.monogram = Self.makeMonogram(from: text)
        self.color = Self.makeColor(from: text)
    }

    private static func makeMonogram(from text: String) -> String {
        let words = text
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

    private static func makeColor(from text: String) -> Color {
        var h: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 1099511628211
        }
        let hue = Double(h % 360) / 360.0
        return Color(hue: hue, saturation: 0.45, brightness: 0.32)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [color, color.opacity(0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(monogram)
                .font(Fonts.serif(size * 0.36, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}
