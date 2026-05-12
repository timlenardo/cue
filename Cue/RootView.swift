import SwiftUI

/// Top-level router. Shows the auth gate when there's no JWT, otherwise the main app.
struct RootView: View {
    @StateObject private var state = AppState()
    @StateObject private var api = CueAPI.shared

    var body: some View {
        Group {
            if api.isAuthenticated {
                ContentView()
                    .environmentObject(state)
                    .environmentObject(api)
            } else {
                AuthView(api: api)
                    .environmentObject(state)
            }
        }
        .preferredColorScheme(state.palette.statusDark ? .dark : .light)
    }
}
