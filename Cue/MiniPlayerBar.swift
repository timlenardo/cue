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
            EpisodeArtworkView(
                urlString: episode.artworkUrl ?? show.artworkUrl,
                fallbackTitle: show.title,
                size: 36,
                radius: 8
            )

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

