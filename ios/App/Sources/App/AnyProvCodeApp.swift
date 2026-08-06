import SwiftUI
import MobileAICore

@main
struct CodeMobileAIApp: App {
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
