import SwiftUI
import AVFAudio

/// Top-level router. Shows the auth gate when there's no JWT, otherwise the main app.
struct RootView: View {
    @StateObject private var state = AppState()
    @StateObject private var api = CueAPI.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if api.isAuthenticated {
                ContentView()
                    .environmentObject(state)
                    .environmentObject(api)
                    .task(id: api.isAuthenticated) {
                        AppStateAccess.current = state
                        await state.reloadLibrary()
                    }
            } else {
                AuthView(api: api)
                    .environmentObject(state)
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
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
    }
}
