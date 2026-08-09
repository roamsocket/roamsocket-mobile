import AppIntents
import Foundation

// MARK: - Open destination intents
//
// These power:
//  • Shortcuts app (Run Shortcut / automation)
//  • Action Button → Shortcuts
//  • Settings → Action Button configuration
//  • Control Center / Lock Screen controls (via ControlWidget)
//  • Spotlight / Siri phrases (AppShortcutsProvider)

struct OpenChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Chat"
    static var description = IntentDescription("Open RoamSocket Chat to talk to your models.")
    static var openAppWhenRun: Bool = true

    static var isDiscoverable: Bool = true

    func perform() async throws -> some IntentResult {
        DeepLinkBridge.request(.chat)
        return .result()
    }
}

struct OpenCodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Code"
    static var description = IntentDescription("Open RoamSocket Code to start or resume a coding session.")
    static var openAppWhenRun: Bool = true

    static var isDiscoverable: Bool = true

    func perform() async throws -> some IntentResult {
        DeepLinkBridge.request(.code)
        return .result()
    }
}

struct OpenVisionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Vision"
    static var description = IntentDescription("Open RoamSocket Vision to analyze the camera or a photo.")
    static var openAppWhenRun: Bool = true

    static var isDiscoverable: Bool = true

    func perform() async throws -> some IntentResult {
        DeepLinkBridge.request(.vision)
        return .result()
    }
}

// MARK: - Bridge (app + extension safe)

/// Lightweight pending-destination store so App Intents (which may run before
/// SwiftUI is ready) can hand off navigation to the main app.
///
/// Uses `UserDefaults` so a Control Center / Lock Screen control that launches
/// the app still lands on the right screen even if process state was cold.
enum DeepLinkBridge {
    private static let defaultsKey = "app.roamsocket.pendingDeepLink.v1"
    private static let notificationName = Notification.Name("app.roamsocket.pendingDeepLink")

    /// Record a destination and notify any listening UI (when the app is warm).
    static func request(_ link: AppDeepLink) {
        UserDefaults.standard.set(link.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: ["destination": link.rawValue]
        )
    }

    /// Consume a pending deep link (clears storage). Returns nil if none.
    static func consume() -> AppDeepLink? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let link = AppDeepLink(rawValue: raw)
        else { return nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return link
    }

    /// Observe new requests while the app is already running.
    static var didRequestNotification: Notification.Name { notificationName }
}
