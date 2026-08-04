import Foundation

/// Represents a skill that can be used in chat
struct Skill: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let iconName: String
    let isEnabled: Bool
    let category: Category
    
    enum Category: String, Equatable {
        case research
        case webSearch = "web_search"
        case health
        case productivity
        case development
        case other
    }
    
    init(
        id: String,
        name: String,
        description: String,
        iconName: String,
        isEnabled: Bool = true,
        category: Category = .other
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.iconName = iconName
        self.isEnabled = isEnabled
        self.category = category
    }
    
    /// Sample skills
    static let sampleSkills: [Skill] = [
        Skill(id: "research", name: "Research", description: "Search and analyze information", iconName: "magnifyingglass", category: .research),
        Skill(id: "web-search", name: "Web Search", description: "Search the web for current information", iconName: "globe", category: .webSearch),
        Skill(id: "health", name: "Health", description: "Access health and fitness data", iconName: "heart.fill", category: .health),
        Skill(id: "calendar", name: "Calendar", description: "Manage calendar events", iconName: "calendar", category: .productivity),
        Skill(id: "email", name: "Email", description: "Send and receive emails", iconName: "envelope.fill", category: .productivity),
        Skill(id: "code", name: "Code Assistant", description: "Help with coding tasks", iconName: "chevron.left.forwardslash.chevron.right", category: .development)
    ]
}
