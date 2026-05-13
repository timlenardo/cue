import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(CueAPI.self) private var api

    var body: some View {
        let palette = state.palette

        ZStack {
            palette.bg.ignoresSafeArea()

            // Main tab content.
            Group {
                switch state.tab {
                case .listen:  EntryView()
                case .library: LibraryView()
                case .notes:   ComingSoonView(title: "Notes")
                }
            }

            // Mini player + tab bar at the bottom. Mini player is visible
            // whenever an episode is loaded and the full player isn't open.
            VStack(spacing: 0) {
                Spacer()
                if state.live != nil && !state.playerOpen {
                    MiniPlayerBar()
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TabBarView()
            }

            // Player sheet — overlays everything when an episode is loaded.
            if state.playerOpen {
                PlayerView()
                    .transition(.move(edge: .bottom))
                    .zIndex(30)
            }
        }
        .animation(.easeOut(duration: 0.28), value: state.tab)
        .animation(.easeOut(duration: 0.28), value: state.playerOpen)
        .animation(.easeOut(duration: 0.22), value: state.live != nil)
    }
}

// MARK: - Coming soon empty state

struct ComingSoonView: View {
    @Environment(AppState.self) private var state
    let title: String

    var body: some View {
        let palette = state.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(Fonts.serif(28, weight: .medium))
                    .tracking(-0.5)
                    .foregroundStyle(palette.ink)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(palette.inkFade)
                Text("Coming soon.")
                    .font(Fonts.serif(18, weight: .medium))
                    .tracking(-0.2)
                    .foregroundStyle(palette.inkMuted)
                Text("\(title) will return once we're past the prototype.")
                    .font(Fonts.sans(13))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .foregroundStyle(palette.inkFade)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
            Spacer(minLength: state.bottomDockHeight + 20)
        }
        .padding(.top, Geo.statusBarReserve)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg.ignoresSafeArea())
    }
}

// MARK: - Tab bar (3 tabs, no center + button)

struct TabBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let palette = state.palette

        HStack(alignment: .top, spacing: 0) {
            tabBtn(.listen, label: "Listen", system: "waveform")
            Spacer(minLength: 0)
            tabBtn(.library, label: "Library", system: "books.vertical")
            Spacer(minLength: 0)
            tabBtn(.notes, label: "Notes", system: "note.text")
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .frame(height: Geo.tabBarHeight)
        .background(
            LinearGradient(
                colors: [palette.bg.opacity(0), palette.bg],
                startPoint: .top,
                endPoint: .center
            )
        )
    }

    @ViewBuilder
    private func tabBtn(_ tab: Tab, label: String, system: String) -> some View {
        let palette = state.palette
        let active = state.tab == tab
        Button {
            state.tab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: system)
                    .font(.system(size: 22, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? palette.ink : palette.inkMuted)
                Text(label)
                    .font(Fonts.sans(10, weight: active ? .bold : .semibold))
                    .tracking(0.5)
                    .foregroundStyle(active ? palette.ink : palette.inkMuted)
            }
            .frame(width: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    RootView()
}
