import SwiftUI
import AVFAudio

/// Top-level router. Shows the auth gate when there's no JWT, otherwise the main app.
struct RootView: View {
    @State private var state = AppState()
    @State private var api = CueAPI.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if api.isAuthenticated {
                ContentView()
                    .environment(state)
                    .environment(api)
                    .task(id: api.isAuthenticated) {
                        AppStateAccess.current = state
                        #if DEBUG
                        if UITestFlag.bypassAuth {
                            // Skip the network reload — tests don't have a real token.
                        } else {
                            await state.reloadLibrary()
                            await state.reloadAllNotes()
                        }
                        if UITestFlag.openSampleLive {
                            // Go through the real `loadLive` flow so the
                            // observed state sequence (live → currentTime →
                            // playerOpen) matches what fires on a library tap.
                            // 60× inflates the sample to ~720 sentences /
                            // ~12k words — same order of magnitude as a real
                            // 1-hour podcast — so LazyVStack exercises its
                            // lazy-loading code path, not the trivial 12-item
                            // case which sizes the entire stack on first pass.
                            //
                            // resumeAt: 600 puts activeIdx ~halfway down the
                            // transcript, so scrollPosition has to perform a
                            // real downward scroll on open — exactly the
                            // codepath that surfaces the bug on the user's
                            // device (they resume mid-episode from library).
                            state.loadLive(
                                SampleLiveEpisodeFactory.make(repeats: 60),
                                resumeAt: 600
                            )
                        } else if UITestFlag.openSamplePlayer {
                            // Open the player without setting `live` — falls
                            // back to SampleData transcript. Useful for
                            // isolating the player-open animation from the
                            // multi-state-mutation that `loadLive` does.
                            state.playerOpen = true
                        }
                        #else
                        await state.reloadLibrary()
                        await state.reloadAllNotes()
                        #endif
                    }
            } else {
                AuthView(api: api)
                    .environment(state)
            }
        }
        .preferredColorScheme(state.palette.statusDark ? .dark : .light)
        .task { await requestMicPermission() }
        .onChange(of: scenePhase) { _, phase in
            state.sceneDidChange(active: phase == .active)
        }
    }

    /// Pre-request mic permission on launch so the first tap on the voice
    /// agent doesn't have to wait on a system prompt.
    private func requestMicPermission() async {
        #if DEBUG
        if UITestFlag.skipMicPermission { return }
        #endif

        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
    }
}
