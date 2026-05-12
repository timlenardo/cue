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
        .task { await requestMicAndStartWake() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:                state.startWakeWord()
            case .background, .inactive: state.stopWakeWord()
            @unknown default:            break
            }
        }
    }

    private func requestMicAndStartWake() async {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            state.startWakeWord()
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if granted { state.startWakeWord() }
        case .denied:
            break // silently disabled; user can enable in Settings
        @unknown default:
            break
        }
    }
}
