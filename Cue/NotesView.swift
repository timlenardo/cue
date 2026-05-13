import SwiftUI

struct NotesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let palette = state.palette

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes")
                    .font(Fonts.serif(28, weight: .medium))
                    .tracking(-0.5)
                    .foregroundStyle(palette.ink)
                Spacer()
                CircleIconButton(palette: palette, system: "magnifyingglass") {}
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            Text("Everything you've asked Cue, plus moments you saved.")
                .font(Fonts.sans(12.5))
                .foregroundStyle(palette.inkMuted)
                .lineSpacing(2)
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 4)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SampleData.notes) { group in
                        NotesGroupView(group: group)
                            .padding(.top, 18)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .padding(.top, 8)
            }
        }
        .padding(.top, Geo.statusBarReserve)
        .padding(.bottom, Geo.bottomDock)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.bg.ignoresSafeArea())
    }
}

private struct NotesGroupView: View {
    @Environment(AppState.self) private var state
    let group: NoteGroup

    var body: some View {
        let palette = state.palette
        let show = SampleData.show(group.showKey)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                CoverTile(showKey: group.showKey, size: 32, radius: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.episode)
                        .font(Fonts.sans(14, weight: .semibold))
                        .tracking(-0.1)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Text("\(show.name) · \(group.when)")
                        .font(Fonts.sans(11))
                        .foregroundStyle(palette.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                    NoteRow(item: item)
                    if idx < group.items.count - 1 {
                        Rectangle()
                            .fill(palette.cardEdge)
                            .frame(height: 0.5)
                            .padding(.leading, 52)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(palette.cardEdge, lineWidth: 0.5)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct NoteRow: View {
    @Environment(AppState.self) private var state
    let item: NoteItem

    var body: some View {
        let palette = state.palette
        let isAsk = item.kind == .ask

        Button {
            state.openPlayer()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isAsk ? palette.accentSoft : palette.subtle)
                    if isAsk {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.accent)
                    } else {
                        Image(systemName: "quote.bubble.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.inkMuted)
                    }
                }
                .frame(width: 26, height: 26)
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(isAsk ? "YOU ASKED" : "SAVED CLIP")
                            .font(Fonts.sans(10.5, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(isAsk ? palette.accent : palette.inkMuted)
                        Text(item.timestamp)
                            .font(Fonts.sans(11))
                            .monospacedDigit()
                            .foregroundStyle(palette.inkFade)
                    }
                    if isAsk {
                        Text(item.body)
                            .font(Fonts.sans(14, weight: .medium))
                            .lineSpacing(3)
                            .foregroundStyle(palette.ink)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text(item.body)
                            .font(.system(size: 15, weight: .regular, design: .serif).italic())
                            .lineSpacing(3)
                            .foregroundStyle(palette.ink)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
