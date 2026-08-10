import UIKit

/// App delegate for system hooks that SwiftUI’s `App` lifecycle does not cover:
/// background URLSession events for on-device model downloads.
final class RoamSocketAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Reconnect the background hub download session on every cold launch.
        LocalMetalBackgroundURLSession.shared.ensureSession()
        LocalMetalBootstrap.ensureRegistered()
        return true
    }

    /// System wakes us when background download tasks complete or need attention.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == LocalMetalBackgroundURLSession.sessionIdentifier else {
            completionHandler()
            return
        }
        LocalMetalBackgroundURLSession.shared.backgroundCompletionHandler = completionHandler
        LocalMetalBackgroundURLSession.shared.ensureSession()
        LocalMetalBootstrap.ensureRegistered()
    }
}
