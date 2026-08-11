import Foundation

/// Schema for marketplace `catalog.json` (connectors, skills, plugins, Metal models).
/// Keep aligned with the official marketplace repo and desktop-server `src/marketplace/types.ts`.
/// Official RoamSocket catalog (external host path below; not product branding).

public let marketplaceSchemaVersion = 1

/// Default official catalog (product owner). Users can add more sources in Settings.
public let defaultMarketplaceURL =
    "https://raw.githubusercontent.com/roamsocket/roamsocket-marketplace/main/catalog.json"

public let defaultMarketplaceSourceID = "roamsocket-official"
/// Previous default source ids remapped on load so users keep one official entry.
public let legacyMarketplaceSourceIDs: Set<String> = ["roamsocket-official"]

public struct MarketplaceConnector: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let icon: String?
    public let available: Bool?
    public let category: String?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        icon: String? = nil,
        available: Bool? = true,
        category: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.available = available
        self.category = category
    }

    public var isAvailable: Bool { available ?? true }
}

public struct MarketplaceSkillListing: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let category: String?
    public let author: String?
    public let source: String?
    public let featured: Bool?
    public let instructions: String?

    public init(
        id: String,
        name: String,
        description: String,
        category: String? = nil,
        author: String? = nil,
        source: String? = nil,
        featured: Bool? = nil,
        instructions: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.author = author
        self.source = source
        self.featured = featured
        self.instructions = instructions
    }
}

public struct MarketplacePlugin: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let category: String?
    public let skillIds: [String]?
    public let featured: Bool?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        category: String? = nil,
        skillIds: [String]? = nil,
        featured: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.skillIds = skillIds
        self.featured = featured
    }
}

public struct MarketplacePluginCategory: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct MarketplaceMetalModel: Codable, Identifiable, Hashable, Sendable {
    public var id: String { hubID }
    public let hubID: String
    public let displayName: String
    public let approxSize: String?
    public let blurb: String?
    public let tags: [String]?
    public let platforms: [String]?

    public init(
        hubID: String,
        displayName: String,
        approxSize: String? = nil,
        blurb: String? = nil,
        tags: [String]? = nil,
        platforms: [String]? = nil
    ) {
        self.hubID = hubID
        self.displayName = displayName
        self.approxSize = approxSize
        self.blurb = blurb
        self.tags = tags
        self.platforms = platforms
    }

    public func supports(platform: String) -> Bool {
        guard let platforms, !platforms.isEmpty else { return true }
        return platforms.map { $0.lowercased() }.contains(platform.lowercased())
    }

    /// Map into LocalMetalCatalogEntry for the Manage models browser.
    public func asLocalMetalEntry() -> LocalMetalCatalogEntry {
        let tagList: [LocalMetalCatalogEntry.Tag] = (tags ?? []).compactMap {
            LocalMetalCatalogEntry.Tag(rawValue: $0)
        }
        return LocalMetalCatalogEntry(
            hubID: hubID,
            displayName: displayName,
            approxSize: approxSize ?? "",
            blurb: blurb ?? "",
            source: .recommended,
            tags: tagList.isEmpty ? [.recommended] : tagList
        )
    }
}

public struct MarketplaceCatalog: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var updatedAt: String?
    public var name: String?
    public var description: String?
    public var connectors: [MarketplaceConnector]
    public var skills: [MarketplaceSkillListing]
    public var plugins: [MarketplacePlugin]
    public var pluginCategories: [MarketplacePluginCategory]
    public var metalModels: [MarketplaceMetalModel]

    public init(
        schemaVersion: Int = marketplaceSchemaVersion,
        updatedAt: String? = nil,
        name: String? = nil,
        description: String? = nil,
        connectors: [MarketplaceConnector] = [],
        skills: [MarketplaceSkillListing] = [],
        plugins: [MarketplacePlugin] = [],
        pluginCategories: [MarketplacePluginCategory] = [],
        metalModels: [MarketplaceMetalModel] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.name = name
        self.description = description
        self.connectors = connectors
        self.skills = skills
        self.plugins = plugins
        self.pluginCategories = pluginCategories
        self.metalModels = metalModels
    }

    public static let empty = MarketplaceCatalog()

    public func metalModels(for platform: String) -> [MarketplaceMetalModel] {
        metalModels.filter { $0.supports(platform: platform) }
    }
}

/// One configured marketplace source (default official or user-added).
public struct MarketplaceSource: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var url: String
    public var enabled: Bool
    public var isDefault: Bool
    public var lastFetchedAt: Date?
    public var lastError: String?
    public var catalogName: String?

    public init(
        id: String,
        name: String,
        url: String,
        enabled: Bool = true,
        isDefault: Bool = false,
        lastFetchedAt: Date? = nil,
        lastError: String? = nil,
        catalogName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
        self.isDefault = isDefault
        self.lastFetchedAt = lastFetchedAt
        self.lastError = lastError
        self.catalogName = catalogName
    }

    public static func makeDefault(url: String = defaultMarketplaceURL) -> MarketplaceSource {
        MarketplaceSource(
            id: defaultMarketplaceSourceID,
            name: "RoamSocket Official",
            url: url,
            enabled: !url.isEmpty,
            isDefault: true
        )
    }
}

public enum MarketplaceURLNormalizer {
    /// Accept raw URLs, `owner/repo`, GitHub blob/tree links.
    public static func normalize(_ input: String) -> String {
        let u = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let blob = u.range(
            of: #"^https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$"#,
            options: .regularExpression
        ) {
            _ = blob
            if let regex = try? NSRegularExpression(
                pattern: #"^https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$"#,
                options: .caseInsensitive
            ),
               let match = regex.firstMatch(in: u, range: NSRange(u.startIndex..., in: u)),
               match.numberOfRanges == 5,
               let o = Range(match.range(at: 1), in: u),
               let r = Range(match.range(at: 2), in: u),
               let b = Range(match.range(at: 3), in: u),
               let p = Range(match.range(at: 4), in: u) {
                return "https://raw.githubusercontent.com/\(u[o])/\(u[r])/\(u[b])/\(u[p])"
            }
        }
        if let regex = try? NSRegularExpression(
            pattern: #"^https?://github\.com/([^/]+)/([^/]+)/tree/([^/]+)/?(.*)$"#,
            options: .caseInsensitive
        ),
           let match = regex.firstMatch(in: u, range: NSRange(u.startIndex..., in: u)),
           match.numberOfRanges >= 4,
           let o = Range(match.range(at: 1), in: u),
           let r = Range(match.range(at: 2), in: u),
           let b = Range(match.range(at: 3), in: u) {
            let rest: String
            if match.numberOfRanges > 4, let p = Range(match.range(at: 4), in: u) {
                rest = String(u[p]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                rest = ""
            }
            let file: String
            if rest.isEmpty {
                file = "catalog.json"
            } else if rest.hasSuffix(".json") {
                file = rest
            } else {
                file = "\(rest)/catalog.json"
            }
            return "https://raw.githubusercontent.com/\(u[o])/\(u[r])/\(u[b])/\(file)"
        }
        // Bare owner/repo → root catalog.json (official layout).
        if u.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil {
            return "https://raw.githubusercontent.com/\(u)/main/catalog.json"
        }
        return u
    }

    public static func isValid(_ url: String) -> Bool {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}

public enum MarketplaceMerge {
    /// Later catalogs override earlier for the same id / hubID.
    public static func merge(_ catalogs: [MarketplaceCatalog]) -> MarketplaceCatalog {
        guard !catalogs.isEmpty else { return .empty }
        var connectors: [String: MarketplaceConnector] = [:]
        var skills: [String: MarketplaceSkillListing] = [:]
        var plugins: [String: MarketplacePlugin] = [:]
        var categories: [String: MarketplacePluginCategory] = [:]
        var metal: [String: MarketplaceMetalModel] = [:]
        var name: String?
        var description: String?
        var updatedAt: String?

        for c in catalogs {
            if let n = c.name { name = n }
            if let d = c.description { description = d }
            if let u = c.updatedAt { updatedAt = u }
            for x in c.connectors { connectors[x.id] = x }
            for x in c.skills { skills[x.id] = x }
            for x in c.plugins { plugins[x.id] = x }
            for x in c.pluginCategories { categories[x.id] = x }
            for x in c.metalModels { metal[x.hubID] = x }
        }

        return MarketplaceCatalog(
            schemaVersion: marketplaceSchemaVersion,
            updatedAt: updatedAt,
            name: name ?? "Merged marketplace",
            description: description,
            connectors: Array(connectors.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            skills: Array(skills.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            plugins: Array(plugins.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            pluginCategories: Array(categories.values),
            metalModels: Array(metal.values)
        )
    }
}
