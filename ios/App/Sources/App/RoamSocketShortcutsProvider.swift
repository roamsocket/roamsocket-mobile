import AppIntents

/// Publishes Chat / Code / Vision so they appear in Shortcuts, Action Button
/// configuration, and Siri suggestions without the user building a shortcut first.
///
/// Lives in the app target only (not the widget extension) so the catalog is
/// registered once.
struct RoamSocketShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenChatIntent(),
            phrases: [
                "Open \(.applicationName) Chat",
                "Chat in \(.applicationName)",
                "Start a chat in \(.applicationName)",
            ],
            shortTitle: "Chat",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
        AppShortcut(
            intent: OpenCodeIntent(),
            phrases: [
                "Open \(.applicationName) Code",
                "Code in \(.applicationName)",
                "Start coding in \(.applicationName)",
            ],
            shortTitle: "Code",
            systemImageName: "chevron.left.forwardslash.chevron.right"
        )
        AppShortcut(
            intent: OpenVisionIntent(),
            phrases: [
                "Open \(.applicationName) Vision",
                "Vision in \(.applicationName)",
                "Analyze with \(.applicationName)",
            ],
            shortTitle: "Vision",
            systemImageName: "eye.fill"
        )
    }
}
