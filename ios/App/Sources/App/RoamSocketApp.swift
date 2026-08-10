import SwiftUI
import AnyProvCore

@main
struct RoamSocketApp: App {
    @UIApplicationDelegateAdaptor(RoamSocketAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState(secrets: KeychainSecretStore())
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // On-device Metal is registered for **chat only** (not coding sessions).
        // Models are never bundled — users download them in Settings.
        LocalMetalBootstrap.ensureRegistered()
        LocalMetalBackgroundURLSession.shared.ensureSession()
        // Apply saved appearance before the first frame so Theme.* tokens match.
        Theme.apply(AppAppearance.resolve(
            rawValue: UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(state.appearance.colorScheme)
                .tint(Theme.accent)
                // Force a full SwiftUI rebuild when the palette changes so every
                // `Theme.*` read picks up the new static colors.
                .id(state.appearanceRaw)
                .onAppear {
                    Theme.apply(state.appearance)
                    // Resume incomplete hub downloads (Range-resumes on-disk blobs).
                    LocalMetalDownloadManager.shared.resumePendingDownloadsIfNeeded(appState: state)
                }
                .onChange(of: state.appearanceRaw) { _, newValue in
                    Theme.apply(AppAppearance.resolve(rawValue: newValue))
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        LocalMetalBackgroundURLSession.shared.ensureSession()
                        LocalMetalDownloadManager.shared.resumePendingDownloadsIfNeeded(appState: state)
                    }
                }
        }
    }
}
