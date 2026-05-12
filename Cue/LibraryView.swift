import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let palette = state.palette

        VStack(alignment: .leading, spacing: 0) {
            // Title row
            HStack(alignment: .center) {
                Text("Library")
                    .font(Fonts.serif(28, weight: .medium))
                    .tracking(-0.5)
                    .foregroundStyle(palette.ink)
                Spacer()
                CircleIconButton(palette: palette, system: "line.3.horizontal") {}
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            // Body scroll
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    NowPlayingCard(ep: SampleData.nowPlaying)
                        .padding(.bottom, 4)

                    SectionLabel(label: "Up next", count: SampleData.queue.count, action: "Edit")

                    VStack(spacing: 0) {
                        ForEach(Array(SampleData.queue.enumerated()), id: \.element.id) { idx, ep in
                            EpisodeRow(ep: ep)
                            if idx < SampleData.queue.count - 1 { Separator() }
                        }
                    }
                    .padding(.horizontal, 6)

                    SectionLabel(label: "Recently played", count: nil, action: "See all")

                    VStack(spacing: 0) {
                        ForEach(Array(SampleData.history.enumerated()), id: \.element.id) { idx, ep in
                            EpisodeRow(ep: ep)
                            if idx < SampleData.history.count - 1 { Separator() }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
        }
        .padding(.top, Geo.statusBarReserve)
        .padding(.bottom, Geo.bottomDock)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.bg.ignoresSafeArea())
    }
}

// MARK: - Now Playing hero

private struct NowPlayingCard: View {
    @EnvironmentObject var state: AppState
    let ep: Episode

    var body: some View {
        let palette = state.palette
        let show = SampleData.show(ep.showKey)
        let remaining = ep.duration * (1 - ep.progress)

        Button {
            state.openPlayer()
        } label: {
            HStack(spacing: 14) {
                CoverTile(showKey: ep.showKey, size: 72, radius: 14)

                VStack(alignment: .leading, spacing: 4) {
                    Text("NOW PLAYING")
                        .font(Fonts.sans(10.5, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(palette.accent)
                    Text(ep.title)
                        .font(Fonts.serif(17, weight: .medium))
                        .tracking(-0.2)
                        .lineSpacing(2)
                        .foregroundStyle(palette.ink)
                        .multilineTextAlignment(.leading)
                    Text("\(show.name) · \(Format.duration(remaining)) left")
                        .font(Fonts.sans(11.5))
                        .foregroundStyle(palette.inkMuted)
                        .padding(.top, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.bg)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(palette.ink))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(palette.cardEdge, lineWidth: 0.5)
                    )
            )
            .shadow(color: show.color.opacity(0.5), radius: 18, y: 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section label

private struct SectionLabel: View {
    @EnvironmentObject var state: AppState
    let label: String
    let count: Int?
    let action: String?

    var body: some View {
        let palette = state.palette
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label.uppercased())
                    .font(Fonts.sans(11, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(palette.inkMuted)
                if let count {
                    Text("\(count)")
                        .font(Fonts.sans(11))
                        .monospacedDigit()
                        .foregroundStyle(palette.inkFade)
                }
            }
            Spacer()
            if let action {
                Button(action) {}
                    .font(Fonts.sans(12, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

// MARK: - Episode row

struct EpisodeRow: View {
    @EnvironmentObject var state: AppState
    let ep: Episode

    var body: some View {
        let palette = state.palette
        let show = SampleData.show(ep.showKey)
        let remaining = ep.duration * (1 - ep.progress)
        let done = ep.progress >= 0.99

        Button {
            state.openPlayer()
        } label: {
            HStack(spacing: 12) {
                CoverTile(showKey: ep.showKey, size: 52, radius: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(show.name) · \(ep.dateLabel)")
                        .font(Fonts.sans(11, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(palette.inkMuted)
                    Text(ep.title)
                        .font(Fonts.sans(14.5, weight: .medium))
                        .tracking(-0.15)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if ep.progress > 0 && ep.progress < 0.99 {
                            ProgressBarMini(progress: ep.progress, accent: palette.accent)
                            Text("\(Format.duration(remaining)) left")
                                .font(Fonts.sans(11))
                                .monospacedDigit()
                                .foregroundStyle(palette.inkMuted)
                        } else if done {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(palette.accent)
                                Text("Played")
                                    .font(Fonts.sans(11))
                                    .foregroundStyle(palette.inkMuted)
                            }
                        } else {
                            Text(Format.duration(ep.duration))
                                .font(Fonts.sans(11))
                                .monospacedDigit()
                                .foregroundStyle(palette.inkSoft)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProgressBarMini: View {
    @EnvironmentObject var state: AppState
    let progress: Double
    let accent: Color

    var body: some View {
        let palette = state.palette
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.subtleStrong)
                Capsule().fill(accent)
                    .frame(width: proxy.size.width * CGFloat(min(1, progress)))
            }
        }
        .frame(height: 3)
    }
}

private struct Separator: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Rectangle()
            .fill(state.palette.cardEdge)
            .frame(height: 0.5)
            .padding(.leading, 64)
    }
}

// MARK: - Shared circle icon button

struct CircleIconButton: View {
    let palette: Palette
    let system: String
    var size: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(palette.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(palette.subtle))
        }
        .buttonStyle(.plain)
    }
}
