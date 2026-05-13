import SwiftUI

struct NotesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let palette = state.palette
        let notes = state.allNotes

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

            Text("Moments you asked Orbit to save while listening.")
                .font(Fonts.sans(12.5))
                .foregroundStyle(palette.inkMuted)
                .lineSpacing(2)
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 4)

            if notes.isEmpty {
                NotesEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(notes) { note in
                        NoteRowView(note: note)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await state.deleteNote(noteId: note.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .refreshable {
                    await state.reloadAllNotes()
                }
            }
        }
        .padding(.top, Geo.statusBarReserve)
        .padding(.bottom, Geo.bottomDock)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.bg.ignoresSafeArea())
        .task {
            // Quietly refresh whenever the tab is opened — keeps the list in
            // sync after a save-note happened in a different session.
            await state.reloadAllNotes()
        }
    }
}

private struct NoteRowView: View {
    @Environment(AppState.self) private var state
    let note: ServerNoteWithEpisode

    var body: some View {
        let palette = state.palette

        Button {
            Task { await openNote() }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                EpisodeArtworkView(
                    urlString: note.episode.showArtworkUrl,
                    fallbackTitle: note.episode.showTitle,
                    size: 44,
                    radius: 9
                )

                VStack(alignment: .leading, spacing: 4) {
                    // Show + episode name. Show name in accent caps, episode
                    // title in muted secondary line.
                    Text(note.episode.showTitle)
                        .font(Fonts.sans(11, weight: .bold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(palette.accent)
                        .lineLimit(1)
                    Text(note.episode.episodeTitle)
                        .font(Fonts.sans(12.5, weight: .medium))
                        .foregroundStyle(palette.inkMuted)
                        .lineLimit(1)

                    // Primary: the note text.
                    Text(note.text)
                        .font(Fonts.sans(15, weight: .medium))
                        .lineSpacing(3)
                        .foregroundStyle(palette.ink)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 2)

                    HStack(spacing: 6) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(palette.accent.opacity(0.85))
                        Text(Format.clock(note.positionSeconds))
                            .font(Fonts.sans(11))
                            .monospacedDigit()
                            .foregroundStyle(palette.inkFade)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(palette.cardEdge, lineWidth: 0.5)
                )
        )
        .contextMenu {
            Button(role: .destructive) {
                Task { await state.deleteNote(noteId: note.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Tap on a note row: if its episode is the one currently playing, just
    /// jump to that point. Otherwise open the episode from the library and
    /// seek there.
    @MainActor
    private func openNote() async {
        if state.live?.serverEpisodeId == note.episodeId {
            state.seek(note.positionSeconds)
            state.openPlayer()
            return
        }
        if let item = state.library.first(where: { $0.episode.id == note.episodeId }) {
            await state.openFromLibrary(item)
            // openFromLibrary resumes at the saved progress — override to
            // the note's anchor point so the tap lands at the moment.
            state.seek(note.positionSeconds)
        } else {
            // Episode no longer in the user's library (removed after the
            // note was saved). Falling back to opening the player on
            // whatever's live is the least surprising thing to do.
            state.openPlayer()
        }
    }
}

private struct NotesEmptyState: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let palette = state.palette
        VStack(spacing: 14) {
            Image(systemName: "bookmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(palette.inkMuted)
            Text("No saved moments yet")
                .font(Fonts.sans(15, weight: .semibold))
                .foregroundStyle(palette.ink)
            Text("Say \u{201C}Orbit, save this\u{201D} while you\u{2019}re listening and the moment will land here.")
                .font(Fonts.sans(12.5))
                .foregroundStyle(palette.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
