import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let palette = state.palette

        VStack(alignment: .leading, spacing: 0) {
            Text("Library")
                .font(Fonts.serif(28, weight: .medium))
                .tracking(-0.5)
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 8)

            if state.library.isEmpty {
                emptyState
            } else {
                listBody
            }
        }
        .padding(.top, Geo.statusBarReserve)
        .padding(.bottom, state.bottomDockHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.bg.ignoresSafeArea())
        .onAppear { state.libraryTabAppeared() }
        .onDisappear { state.libraryTabDisappeared() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        let palette = state.palette
        return VStack {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "headphones")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(palette.inkFade)
                Text("No episodes yet.")
                    .font(Fonts.serif(18, weight: .medium))
                    .tracking(-0.2)
                    .foregroundStyle(palette.inkMuted)
                Text("Paste a podcast link on the Listen tab. Episodes you start will show up here.")
                    .font(Fonts.sans(13))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .foregroundStyle(palette.inkFade)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    // MARK: - List

    private var listBody: some View {
        let items = state.library
        let hero = items.first
        let rest = Array(items.dropFirst())
        let restCount = rest.count

        return List {
            if let hero {
                NowPlayingCard(item: hero)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Analytics.shared.track(
                                "library_episode_removed",
                                properties: [
                                    "episode_id": hero.episode.id,
                                    "via": "swipe",
                                ]
                            )
                            Task { await state.removeFromLibrary(episodeId: hero.episode.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }

            if !rest.isEmpty {
                Section {
                    ForEach(Array(rest.enumerated()), id: \.element.id) { idx, item in
                        EpisodeRow(item: item, showBottomSeparator: idx < restCount - 1)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Analytics.shared.track(
                                        "library_episode_removed",
                                        properties: [
                                            "episode_id": item.episode.id,
                                            "via": "swipe",
                                        ]
                                    )
                                    Task { await state.removeFromLibrary(episodeId: item.episode.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    SectionLabel(label: "Up next", count: restCount)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .refreshable {
            await state.reloadLibrary()
        }
    }
}

// MARK: - Now-playing hero

private struct NowPlayingCard: View {
    @Environment(AppState.self) private var state
    let item: LibraryItem

    var body: some View {
        let palette = state.palette
        let ep = item.episode
        let progress = ep.durationSeconds.map { item.positionSeconds / max(1, $0) } ?? 0
        let remaining = (ep.durationSeconds ?? 0) - item.positionSeconds
        let inProgress = item.positionSeconds > 0 && item.completedAt == nil
        let display = LibraryCardDisplay(ep: ep)

        let subline: String = {
            switch ep.status {
            case .processing, .failed:
                return display.showLine
            case .ready:
                if ep.durationSeconds != nil && inProgress {
                    return "\(display.showLine) · \(Format.duration(remaining)) left"
                }
                if let total = ep.durationSeconds {
                    return "\(display.showLine) · \(Format.duration(total))"
                }
                return display.showLine
            }
        }()

        let isLive = state.isLive(episodeId: ep.id)
        let isPlayingNow = state.isPlaying(episodeId: ep.id)
        let eyebrow: String = {
            switch ep.status {
            case .processing: return "GENERATING AUDIO"
            case .failed:     return "COULDN'T GENERATE AUDIO"
            case .ready:
                if isLive && isPlayingNow { return "NOW PLAYING" }
                if isLive { return "PAUSED" }
                if inProgress { return "RESUME" }
                if item.completedAt != nil { return "PLAYED" }
                return "READY TO PLAY"
            }
        }()
        let eyebrowColor: Color = ep.status == .failed
            ? Color(hex: "FF453A")
            : palette.accent
        let isTappable = ep.status == .ready

        HStack(spacing: 14) {
            EpisodeArtworkView(
                urlString: display.thumbnailUrl,
                fallbackTitle: display.showLine,
                size: 72,
                radius: 14
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(Fonts.sans(10.5, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(eyebrowColor)
                Text(ep.episodeTitle)
                    .font(Fonts.serif(17, weight: .medium))
                    .tracking(-0.2)
                    .lineSpacing(2)
                    .foregroundStyle(palette.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Text(subline)
                    .font(Fonts.sans(11.5))
                    .foregroundStyle(palette.inkMuted)
                    .padding(.top, 1)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isTappable else { return }
                if isLive {
                    state.openPlayer()
                } else {
                    Task { await state.openFromLibrary(item) }
                }
            }

            // Trailing affordance varies by status:
            //  - ready: play/pause button (existing behavior)
            //  - processing: spinner; tap is a no-op
            //  - failed: nothing inline — the row's leading-swipe trash
            //    + context-menu Remove still apply
            switch ep.status {
            case .ready:
                Button {
                    if isLive {
                        state.togglePlay()
                    } else {
                        Task { await state.openFromLibrary(item) }
                    }
                } label: {
                    Image(systemName: isPlayingNow ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.bg)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(palette.ink))
                }
                .buttonStyle(.plain)
            case .processing:
                ProgressView()
                    .tint(palette.inkMuted)
                    .frame(width: 40, height: 40)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(hex: "FF453A").opacity(0.85))
                    .frame(width: 40, height: 40)
            }
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
        .overlay(alignment: .bottom) {
            if ep.status == .ready, inProgress, ep.durationSeconds != nil {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.subtleStrong)
                        Capsule().fill(palette.accent)
                            .frame(width: proxy.size.width * CGFloat(min(1, progress)))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Analytics.shared.track(
                    "library_episode_removed",
                    properties: [
                        "episode_id": ep.id,
                        "via": "context_menu",
                    ]
                )
                Task { await state.removeFromLibrary(episodeId: ep.id) }
            } label: {
                Label("Remove from library", systemImage: "trash")
            }
        }
    }
}

// MARK: - Section label

private struct SectionLabel: View {
    @Environment(AppState.self) private var state
    let label: String
    let count: Int?

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
        }
        .padding(.horizontal, 6)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

// MARK: - Episode row

private struct EpisodeRow: View {
    @Environment(AppState.self) private var state
    let item: LibraryItem
    var showBottomSeparator: Bool = false

    var body: some View {
        let palette = state.palette
        let ep = item.episode
        let inProgress = item.positionSeconds > 0 && item.completedAt == nil
        let progress = ep.durationSeconds.map { item.positionSeconds / max(1, $0) } ?? 0
        let remaining = (ep.durationSeconds ?? 0) - item.positionSeconds
        let done = item.completedAt != nil
        let display = LibraryCardDisplay(ep: ep)

        Button {
            // Processing/failed rows are tap-no-op; openFromLibrary also
            // guards on status==ready but bailing here keeps the row from
            // animating into a press state for a request we'll discard.
            guard ep.status == .ready else { return }
            Task { await state.openFromLibrary(item) }
        } label: {
            HStack(spacing: 12) {
                EpisodeArtworkView(
                    urlString: display.thumbnailUrl,
                    fallbackTitle: display.showLine,
                    size: 52,
                    radius: 10
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(display.showLine)
                        .font(Fonts.sans(11, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(palette.inkMuted)
                        .lineLimit(1)
                    Text(ep.episodeTitle)
                        .font(Fonts.sans(14.5, weight: .medium))
                        .tracking(-0.15)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        switch ep.status {
                        case .processing:
                            ProgressView()
                                .controlSize(.mini)
                                .tint(palette.inkMuted)
                            Text("Generating audio\u{2026}")
                                .font(Fonts.sans(11))
                                .foregroundStyle(palette.inkMuted)
                        case .failed:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(hex: "FF453A"))
                            Text("Couldn't generate audio")
                                .font(Fonts.sans(11))
                                .foregroundStyle(palette.inkMuted)
                        case .ready:
                            if inProgress {
                                ProgressBarMini(progress: progress, accent: palette.accent)
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
                            } else if let dur = ep.durationSeconds {
                                Text(Format.duration(dur))
                                    .font(Fonts.sans(11))
                                    .monospacedDigit()
                                    .foregroundStyle(palette.inkSoft)
                            } else {
                                Text("Ready")
                                    .font(Fonts.sans(11))
                                    .foregroundStyle(palette.inkSoft)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if showBottomSeparator {
                    Rectangle()
                        .fill(palette.cardEdge)
                        .frame(height: 0.5)
                        .padding(.leading, 64)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Analytics.shared.track(
                    "library_episode_removed",
                    properties: [
                        "episode_id": ep.id,
                        "via": "context_menu",
                    ]
                )
                Task { await state.removeFromLibrary(episodeId: ep.id) }
            } label: {
                Label("Remove from library", systemImage: "trash")
            }
        }
    }
}

// MARK: - Helpers

private struct ProgressBarMini: View {
    @Environment(AppState.self) private var state
    let progress: Double
    let accent: Color

    var body: some View {
        let palette = state.palette
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.subtleStrong)
                Capsule().fill(accent)
                    .frame(width: proxy.size.width * CGFloat(min(1, max(0, progress))))
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Article vs podcast display helper

/// Chooses the "show" line and thumbnail per the article-vs-podcast
/// branding rules in the article-TTS brief: article rows surface the
/// site name and `featuredImage`; podcasts keep their existing show
/// title and artwork.
private struct LibraryCardDisplay {
    let showLine: String
    let thumbnailUrl: String?

    init(ep: ServerEpisode) {
        if ep.source == "article", let meta = ep.articleSourceMetadata {
            self.showLine = (meta.siteName?.isEmpty == false ? meta.siteName : nil) ?? ep.showTitle
            self.thumbnailUrl = meta.featuredImage ?? ep.episodeArtworkUrl ?? ep.showArtworkUrl
        } else {
            self.showLine = ep.showTitle
            self.thumbnailUrl = ep.episodeArtworkUrl ?? ep.showArtworkUrl
        }
    }
}

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
