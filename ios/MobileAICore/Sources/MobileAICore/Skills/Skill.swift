import Foundation

/// A development skill that provides guidance to the AI agent.
public struct Skill: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let content: String
    public let category: SkillCategory
    public let source: SkillSource
    public var isEnabled: Bool
    
    public init(
        id: String,
        name: String,
        description: String,
        content: String,
        category: SkillCategory,
        source: SkillSource,
        isEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.content = content
        self.category = category
        self.source = source
        self.isEnabled = isEnabled
    }
}

public enum SkillCategory: String, Codable, CaseIterable, Sendable {
    case frontend = "Frontend"
    case fullstack = "Full Stack"
    case mobile = "Mobile"
    case devops = "DevOps"
    case database = "Database"
    case testing = "Testing"
    case documentation = "Documentation"
    case design = "Design"
    case other = "Other"
    
    public var icon: String {
        switch self {
        case .frontend: return "paintbrush"
        case .fullstack: return "square.stack.3d.up"
        case .mobile: return "iphone"
        case .devops: return "gearshape.2"
        case .database: return "cylinder"
        case .testing: return "checkmark.seal"
        case .documentation: return "doc.text"
        case .design: return "paintpalette"
        case .other: return "star"
        }
    }
}

public enum SkillSource: String, Codable, Sendable {
    case official = "Official"
    case community = "Community"
    case custom = "Custom"
}
