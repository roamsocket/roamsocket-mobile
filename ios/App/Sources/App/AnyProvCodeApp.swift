import SwiftUI
import AnyProvCore

@main
struct AnyProvCodeApp: App {
    @StateObject private var state = AppState(secrets: KeychainSecretStore())

    init() {
        // On-device Metal is registered for **chat only** (not coding sessions).
        // Models are never bundled — users download them in Settings.
        LocalMetalBootstrap.ensureRegistered()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
