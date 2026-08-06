import SwiftUI
import AnyProvCore

@main
struct AnyProvCodeApp: App {
    @StateObject private var state = AppState(secrets: KeychainSecretStore())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
