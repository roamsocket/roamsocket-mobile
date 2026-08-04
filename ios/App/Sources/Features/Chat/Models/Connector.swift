import Foundation

/// Represents a connector integration (e.g., Gmail, Google Calendar, etc.)
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
    
    /// Sample connectors matching the screenshots
    static let sampleConnectors: [Connector] = [
        Connector(id: "cashapp", name: "Cash App", iconName: "dollarsign.circle.fill", itemCount: 5),
        Connector(id: "figma", name: "Figma", iconName: "paintbrush.fill", itemCount: 27),
        Connector(id: "gmail", name: "Gmail", iconName: "envelope.fill", itemCount: 16),
        Connector(id: "google-calendar", name: "Google Calendar", iconName: "calendar", itemCount: 9),
        Connector(id: "google-drive", name: "Google Drive", iconName: "cloud.fill", itemCount: 8),
        Connector(id: "granola", name: "Granola", iconName: "note.text", itemCount: 6),
        Connector(id: "higgsfield", name: "Higgsfield", iconName: "sparkles", itemCount: 85),
        Connector(id: "hubspot", name: "HubSpot", iconName: "chart.bar.fill", itemCount: 21),
        Connector(id: "indeed", name: "Indeed", iconName: "briefcase.fill", itemCount: 4),
        Connector(id: "linear", name: "Linear", iconName: "circle.hexagongrid.fill", itemCount: 52),
        Connector(id: "mercury", name: "Mercury", iconName: "banknote.fill", itemCount: 35)
    ]
}
