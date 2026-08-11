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
    /// Raw frontmatter parsed from SKILL.md; preserved across edits so we
    /// can round-trip the file unchanged when the user hasn't touched it.
    public var frontmatter: [String: String]

    public init(
        id: String,
        name: String,
        description: String,
        content: String,
        category: SkillCategory,
        source: SkillSource,
        isEnabled: Bool = false,
        frontmatter: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.content = content
        self.category = category
        self.source = source
        self.isEnabled = isEnabled
        self.frontmatter = frontmatter
    }

    /// Re-render the SKILL.md file from the current fields.
    public var fullText: String {
        var yaml = "---\n"
        let keys = frontmatter.keys.sorted()
        let ordered: [String] = keys.contains("name") && keys.contains("description") ?
            (keys.filter { $0 != "name" && $0 != "description" } + ["name", "description"]).reversed() :
            keys
        for key in ordered where key != "name" && key != "description" {
            yaml += "\(key): \(frontmatter[key] ?? "")\n"
        }
        yaml += "name: \(name)\n"
        yaml += "description: \(description)\n"
        yaml += "---\n\n"
        return yaml + content
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

    /// Map a free-form marketplace category string (e.g. "devops", "frontend")
    /// to the closest enum case, defaulting to `.other`.
    public static func from(marketplaceCategory raw: String?) -> SkillCategory {
        guard let raw else { return .other }
        let lower = raw.lowercased()
        for c in allCases where c.rawValue.lowercased() == lower { return c }
        if lower == "full stack" || lower == "fullstack" { return .fullstack }
        return .other
    }
}

public enum SkillSource: String, Codable, Sendable {
    case official = "Official"
    case community = "Community"
    case custom = "Custom"

    /// Map a marketplace source string (e.g. "official", "community") to the
    /// enum, defaulting to `.community` for unknown values.
    public static func from(marketplaceSource raw: String?) -> SkillSource {
        guard let raw else { return .community }
        let lower = raw.lowercased()
        if lower == "official" { return .official }
        if lower == "custom" { return .custom }
        return .community
    }
}
