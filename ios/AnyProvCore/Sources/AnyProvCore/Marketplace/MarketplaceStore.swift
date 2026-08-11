import Foundation

/// Multi-source marketplace store for iOS: default official catalog + user-added repos.
/// Mirrors desktop-server `src/marketplace/store.ts`.
@MainActor
public final class MarketplaceStore: ObservableObject {
    public static let shared = MarketplaceStore()

    private let sourcesKey = "roamsocket.marketplace.sources.v1"
    private let cacheKey = "roamsocket.marketplace.cache.v1"
    private let perSourceKey = "roamsocket.marketplace.perSource.v1"
    private let lastMergedKey = "roamsocket.marketplace.lastMerged.v1"
    /// Pre-rename UserDefaults keys (migrate once on load).
    private let legacySourcesKey = "roamsocket.marketplace.sources.v1"
    private let legacyCacheKey = "roamsocket.marketplace.cache.v1"
    private let legacyPerSourceKey = "roamsocket.marketplace.perSource.v1"
    private let legacyLastMergedKey = "roamsocket.marketplace.lastMerged.v1"

    @Published public private(set) var sources: [MarketplaceSource] = []
    @Published public private(set) var catalog: MarketplaceCatalog = .empty
    @Published public private(set) var lastMergedAt: Date?
    @Published public private(set) var usingBundledOnly: Bool = true
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastRefreshError: String?

    private var perSourceCache: [String: MarketplaceCatalog] = [:]

    public init() {
        loadPersisted()
        if catalog.connectors.isEmpty && catalog.metalModels.isEmpty {
            catalog = Self.bundledCatalog
            usingBundledOnly = true
        }
    }

    // MARK: - Public API

    public var connectors: [MarketplaceConnector] { catalog.connectors }
    public var skills: [MarketplaceSkillListing] { catalog.skills }
    public var plugins: [MarketplacePlugin] { catalog.plugins }
    public var pluginCategories: [MarketplacePluginCategory] { catalog.pluginCategories }

    public var iosMetalModels: [MarketplaceMetalModel] {
        catalog.metalModels(for: "ios")
    }

    public var iosRecommendedMetalEntries: [LocalMetalCatalogEntry] {
        iosMetalModels.map { $0.asLocalMetalEntry() }
    }

    @discardableResult
    public func addSource(name: String?, url rawURL: String, enabled: Bool = true) throws -> MarketplaceSource {
        let url = MarketplaceURLNormalizer.normalize(rawURL)
        guard MarketplaceURLNormalizer.isValid(url) else {
            throw MarketplaceError.invalidURL
        }
        if sources.contains(where: { $0.url == url }) {
            throw MarketplaceError.duplicateURL
        }
        let id = "user-\(UUID().uuidString.prefix(8).lowercased())"
        let derived = derivedName(from: url)
        let src = MarketplaceSource(
            id: id,
            name: (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                   ? name!.trimmingCharacters(in: .whitespacesAndNewlines)
                   : derived),
            url: url,
            enabled: enabled,
            isDefault: false
        )
        sources.append(src)
        persistSources()
        return src
    }

    public func removeSource(id: String) throws {
        guard let src = sources.first(where: { $0.id == id }) else {
            throw MarketplaceError.notFound
        }
        if src.isDefault || isOfficialSourceId(src.id) {
            throw MarketplaceError.cannotRemoveDefault
        }
        sources.removeAll { $0.id == id }
        perSourceCache.removeValue(forKey: id)
        persistSources()
        persistCache()
    }

    public func setSourceEnabled(id: String, enabled: Bool) throws {
        guard let idx = sources.firstIndex(where: { $0.id == id }) else {
            throw MarketplaceError.notFound
        }
        sources[idx].enabled = enabled
        persistSources()
    }

    public func setSourceURL(id: String, url rawURL: String) throws {
        let url = MarketplaceURLNormalizer.normalize(rawURL)
        guard MarketplaceURLNormalizer.isValid(url) else {
            throw MarketplaceError.invalidURL
        }
        guard let idx = sources.firstIndex(where: { $0.id == id }) else {
            throw MarketplaceError.notFound
        }
        sources[idx].url = url
        sources[idx].lastError = nil
        persistSources()
    }

    /// Fetch enabled sources, merge with bundled baseline, apply cache.
    public func refresh() async {
        isRefreshing = true
        lastRefreshError = nil
        defer { isRefreshing = false }

        var fetched: [MarketplaceCatalog] = []
        var anyRemoteOk = false
        var updated = sources

        for i in updated.indices {
            guard updated[i].enabled, !updated[i].url.isEmpty else { continue }
            do {
                let cat = try await fetchCatalog(url: updated[i].url)
                anyRemoteOk = true
                perSourceCache[updated[i].id] = cat
                fetched.append(cat)
                updated[i].lastFetchedAt = Date()
                updated[i].lastError = nil
                updated[i].catalogName = cat.name ?? updated[i].name
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                updated[i].lastError = message
                if let cached = perSourceCache[updated[i].id] {
                    fetched.append(cached)
                    anyRemoteOk = true
                }
            }
        }

        sources = updated
        persistSources()

        let merged = MarketplaceMerge.merge([Self.bundledCatalog] + fetched)
        catalog = merged
        usingBundledOnly = !anyRemoteOk
        if anyRemoteOk {
            lastMergedAt = Date()
        }
        if !anyRemoteOk && fetched.isEmpty {
            catalog = Self.bundledCatalog
            usingBundledOnly = true
        }
        persistCache()

        // Push Metal recommended list into LocalMetalCatalog.
        await LocalMetalCatalog.shared.applyMarketplaceRecommended(iosRecommendedMetalEntries)

        if !anyRemoteOk {
            lastRefreshError = updated.compactMap(\.lastError).first ?? "Could not refresh marketplaces"
        }
    }

    // MARK: - Persistence

    private func loadPersisted() {
        migrateLegacyKeysIfNeeded()

        if let data = UserDefaults.standard.data(forKey: sourcesKey),
           let decoded = try? JSONDecoder().decode([MarketplaceSource].self, from: data),
           !decoded.isEmpty {
            sources = ensureDefault(decoded)
        } else {
            sources = [MarketplaceSource.makeDefault()]
        }

        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode(MarketplaceCatalog.self, from: data) {
            catalog = decoded
            usingBundledOnly = false
        }

        if let data = UserDefaults.standard.data(forKey: perSourceKey),
           let decoded = try? JSONDecoder().decode([String: MarketplaceCatalog].self, from: data) {
            // Remap legacy official source id in per-source cache.
            var remapped: [String: MarketplaceCatalog] = [:]
            for (id, cat) in decoded {
                if legacyMarketplaceSourceIDs.contains(id) {
                    remapped[defaultMarketplaceSourceID] = cat
                } else {
                    remapped[id] = cat
                }
            }
            perSourceCache = remapped
        }

        lastMergedAt = UserDefaults.standard.object(forKey: lastMergedKey) as? Date
    }

    /// Copy legacy pre-rename UserDefaults keys into current RoamSocket keys once.
    private func migrateLegacyKeysIfNeeded() {
        let defaults = UserDefaults.standard
        let pairs = [
            (legacySourcesKey, sourcesKey),
            (legacyCacheKey, cacheKey),
            (legacyPerSourceKey, perSourceKey),
            (legacyLastMergedKey, lastMergedKey),
        ]
        for (legacy, current) in pairs {
            guard defaults.object(forKey: current) == nil,
                  let value = defaults.object(forKey: legacy) else { continue }
            defaults.set(value, forKey: current)
            defaults.removeObject(forKey: legacy)
        }
    }

    private func persistSources() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: sourcesKey)
        }
    }

    private func persistCache() {
        if let data = try? JSONEncoder().encode(catalog) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        if let data = try? JSONEncoder().encode(perSourceCache) {
            UserDefaults.standard.set(data, forKey: perSourceKey)
        }
        if let lastMergedAt {
            UserDefaults.standard.set(lastMergedAt, forKey: lastMergedKey)
        }
    }

    private func isOfficialSourceId(_ id: String) -> Bool {
        id == defaultMarketplaceSourceID || legacyMarketplaceSourceIDs.contains(id)
    }

    private func ensureDefault(_ list: [MarketplaceSource]) -> [MarketplaceSource] {
        let def = MarketplaceSource.makeDefault()
        let without = list.filter { !$0.isDefault && !isOfficialSourceId($0.id) }
        if let existing = list.first(where: { $0.isDefault || isOfficialSourceId($0.id) }) {
            var e = existing
            e.isDefault = true
            if e.id != defaultMarketplaceSourceID {
                e = MarketplaceSource(
                    id: defaultMarketplaceSourceID,
                    name: e.name.isEmpty ? def.name : e.name,
                    url: e.url.isEmpty ? def.url : e.url,
                    enabled: e.enabled,
                    isDefault: true,
                    lastFetchedAt: e.lastFetchedAt,
                    lastError: e.lastError,
                    catalogName: e.catalogName
                )
            }
            return [e] + without
        }
        return [def] + without
    }

    private func fetchCatalog(url: String) async throws -> MarketplaceCatalog {
        guard let u = URL(string: url) else { throw MarketplaceError.invalidURL }
        var req = URLRequest(url: u)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("RoamSocket-iOS/marketplace", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarketplaceError.httpStatus(http.statusCode)
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(MarketplaceCatalog.self, from: data)
        } catch {
            throw MarketplaceError.invalidSchema
        }
    }

    private func derivedName(from url: String) -> String {
        guard let u = URL(string: url) else { return "Marketplace" }
        let parts = u.path.split(separator: "/").map(String.init)
        if u.host?.contains("githubusercontent.com") == true, parts.count >= 2 {
            return "\(parts[0])/\(parts[1])"
        }
        if u.host == "github.com", parts.count >= 2 {
            return "\(parts[0])/\(parts[1])"
        }
        return u.host ?? "Marketplace"
    }

    /// Bundled offline fallback (subset matching official catalog.json).
    nonisolated public static let bundledCatalog: MarketplaceCatalog = MarketplaceCatalog(
        schemaVersion: marketplaceSchemaVersion,
        updatedAt: "2026-08-07",
        name: "RoamSocket Official Marketplace",
        description: "Bundled offline fallback.",
        connectors: [
            .init(id: "cashapp", name: "Cash App", available: true, category: "finance"),
            .init(id: "figma", name: "Figma", available: true, category: "design"),
            .init(id: "gmail", name: "Gmail", available: true, category: "productivity"),
            .init(id: "godaddy", name: "GoDaddy", available: true, category: "web"),
            .init(id: "gcal", name: "Google Calendar", available: true, category: "productivity"),
            .init(id: "gdrive", name: "Google Drive", available: true, category: "productivity"),
            .init(id: "granola", name: "Granola", available: false, category: "productivity"),
            .init(id: "github", name: "GitHub", available: true, category: "engineering"),
        ],
        skills: [
            .init(id: "mcp-builder", name: "mcp-builder", description: "Guide for creating high-quality MCP servers", category: "devops", source: "official", featured: true, instructions: "# MCP Builder\n\nGuide for creating high-quality MCP (Model Context Protocol) servers that enable LLMs to interact with external tools and data sources.\n\n## Goals\n- Clear tool schemas and descriptions\n- Safe auth and error handling\n- Idiomatic TypeScript / Python server layouts\n\n## Invocation\n- \"build an MCP server\"\n- \"add tools for …\"\n- \"/mcp-builder\"\n"),
            .init(id: "skill-creator", name: "skill-creator", description: "Author new agent skills", category: "other", source: "official", featured: true, instructions: "# Skill Creator\n\nHelp the user design SKILL.md files: name, description, triggers, and instructions.\n\n## Invocation\n- \"create a skill\"\n- \"skill for …\"\n"),
            .init(id: "frontend-design-css", name: "frontend-design-css", description: "Premium HTML Landing Page Generator", category: "frontend", source: "official", featured: true, instructions: "# Landing — Premium HTML Landing Page Generator\n\nGenerate a polished, self-contained `.html` landing page from a text prompt or brief. The output is ONE HTML file: all CSS inline in `<style>`, all JS inline in `<script>`, only external dependencies being Google Fonts + GSAP via CDN. The page is visually distinctive, animated, and production-quality.\n\n## Invocation Triggers\n- \"create a landing page\"\n- \"build a landing page\"\n- \"make a landing page for X\"\n- \"I need a web page for Y\"\n"),
        ],
        plugins: [
            .init(id: "engineering-kit", name: "Engineering kit", description: "MCP builders and developer-oriented skills.", category: "engineering", skillIds: ["mcp-builder", "skill-creator"], featured: true),
        ],
        pluginCategories: [
            .init(id: "marketing", label: "Marketing"),
            .init(id: "productivity", label: "Productivity"),
            .init(id: "engineering", label: "Engineering"),
            .init(id: "design", label: "Design"),
        ],
        metalModels: [
            .init(
                hubID: "lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit",
                displayName: "LFM2.5 1.2B",
                approxSize: "~0.7 GB",
                blurb: "Liquid AI LFM2.5 — strong everyday chat and a great on-device starting point.",
                tags: ["recommended", "best", "new"],
                platforms: ["ios", "desktop"]
            ),
            .init(
                hubID: "lmstudio-community/Qwen3-1.7B-MLX-4bit",
                displayName: "Qwen 3 1.7B",
                approxSize: "~1.0 GB",
                blurb: "Balanced Qwen 3 size for everyday on-device chat.",
                tags: ["recommended", "new"],
                platforms: ["ios", "desktop"]
            ),
            .init(
                hubID: "lmstudio-community/Qwen3-0.6B-MLX-4bit",
                displayName: "Qwen 3 0.6B",
                approxSize: "~0.4 GB",
                blurb: "Tiny Qwen 3 for low storage and fast replies.",
                tags: ["recommended", "new"],
                platforms: ["ios", "desktop"]
            ),
            .init(
                hubID: "lmstudio-community/gemma-3-270m-it-qat-MLX-4bit",
                displayName: "Gemma 3 270M QAT",
                approxSize: "~0.2 GB",
                blurb: "Tiny Gemma for smoke tests and ultra-low storage.",
                tags: ["recommended"],
                platforms: ["ios", "desktop"]
            ),
        ]
    )
}

public enum MarketplaceError: Error, LocalizedError {
    case invalidURL
    case duplicateURL
    case notFound
    case cannotRemoveDefault
    case httpStatus(Int)
    case invalidSchema

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid http(s) catalog URL, owner/repo, or GitHub link."
        case .duplicateURL:
            return "That marketplace URL is already added."
        case .notFound:
            return "Marketplace not found."
        case .cannotRemoveDefault:
            return "The official marketplace cannot be removed. Disable it instead."
        case .httpStatus(let code):
            return "HTTP \(code) fetching marketplace."
        case .invalidSchema:
            return "catalog.json did not match the marketplace schema."
        }
    }
}
