//
//  CueApp.swift
//  Cue
//
//  Created by Timothy Lenardo on 5/11/26.
//

import SwiftUI

@main
struct CueApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .onChange(of: scenePhase) { _, phase in
                    // When the app backgrounds (or returns), make sure the
                    // server has the latest playback position.
                    if phase == .background || phase == .inactive {
                        AppStateAccess.current?.syncProgress(force: true)
                    }
                }
        }
    }
}

/// Lets the App layer reach AppState for one-off events (scene transitions)
/// without making AppState a singleton.
@MainActor
enum AppStateAccess {
    static weak var current: AppState?
}
