import Foundation

/// Represents a connector integration (e.g., Gmail, Google Calendar, etc.)
/// surfaced in the chat composer. Real connector data flows from the desktop
/// server via the coding session — the iOS app only stores the user's
/// preferences (which connector ids are attached to a chat).
struct Connector: Identifiable, Equatable {
    let id: String
    let name: String
    let iconName: String
    let itemCount: Int
    let isEnabled: Bool
    let description: String?

    init(
        id: String,
        name: String,
        iconName: String,
        itemCount: Int,
        isEnabled: Bool = true,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.itemCount = itemCount
        self.isEnabled = isEnabled
        self.description = description
    }
}
