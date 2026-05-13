import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let palette = state.palette

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Library")
                    .font(Fonts.serif(28, weight: .medium))
                    .tracking(-0.5)
                    .foregroundStyle(palette.ink)
                Spacer()
                CircleIconButton(palette: palette, system: "arrow.clockwise") {
                    Task { await state.reloadLibrary() }
                }
            }
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

        return ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                if let hero {
                    NowPlayingCard(item: hero)
                        .padding(.bottom, 4)
                }

                if !rest.isEmpty {
                    SectionLabel(label: "Up next", count: rest.count)
                    VStack(spacing: 0) {
                        ForEach(Array(rest.enumerated()), id: \.element.id) { idx, item in
                            EpisodeRow(item: item)
                            if idx < rest.count - 1 { Separator() }
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
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

        let subline: String = {
            if ep.durationSeconds != nil && inProgress {
                return "\(ep.showTitle) · \(Format.duration(remaining)) left"
            }
            if let total = ep.durationSeconds {
                return "\(ep.showTitle) · \(Format.duration(total))"
            }
            return ep.showTitle
        }()

        let isLive = state.isLive(episodeId: ep.id)
        let isPlayingNow = state.isPlaying(episodeId: ep.id)
        let eyebrow: String = {
            if isLive && isPlayingNow { return "NOW PLAYING" }
            if isLive { return "PAUSED" }
            if inProgress { return "RESUME" }
            if item.completedAt != nil { return "PLAYED" }
            return "READY TO PLAY"
        }()

        HStack(spacing: 14) {
            ShowMonogram(text: ep.showTitle, size: 72, radius: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(Fonts.sans(10.5, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(palette.accent)
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
                if isLive {
                    state.openPlayer()
                } else {
                    Task { await state.openFromLibrary(item) }
                }
            }

            // Trailing play/pause button — reflects live playback when this
            // episode is the active one, otherwise loads + plays from library.
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
            if inProgress, ep.durationSeconds != nil {
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

    var body: some View {
        let palette = state.palette
        let ep = item.episode
        let inProgress = item.positionSeconds > 0 && item.completedAt == nil
        let progress = ep.durationSeconds.map { item.positionSeconds / max(1, $0) } ?? 0
        let remaining = (ep.durationSeconds ?? 0) - item.positionSeconds
        let done = item.completedAt != nil

        Button {
            Task { await state.openFromLibrary(item) }
        } label: {
            HStack(spacing: 12) {
                ShowMonogram(text: ep.showTitle, size: 52, radius: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(ep.showTitle)
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
        .contextMenu {
            Button(role: .destructive) {
                Task { await state.removeFromLibrary(episodeId: ep.id) }
            } label: {
                Label("Remove from library", systemImage: "trash")
            }
        }
    }
}

// MARK: - Generic show monogram (no SampleData dependency)

private struct ShowMonogram: View {
    let text: String
    let size: CGFloat
    let radius: CGFloat

    // Computed once at init; body reads cached values. Library rows can be
    // rebuilt as the user scrolls / paginates, so even though the inner
    // text rarely changes, recomputing the FNV-1a hash per body adds up.
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

    /// Deterministic dark color from the show-title hash.
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

private struct Separator: View {
    @Environment(AppState.self) private var state
    var body: some View {
        Rectangle()
            .fill(state.palette.cardEdge)
            .frame(height: 0.5)
            .padding(.leading, 64)
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
