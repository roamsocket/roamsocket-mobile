import Foundation
import AnyProvCore

/// Snapshot of the iOS app's user settings, written to a GitHub repo the
/// user owns (default: `anyprov-code-settings`) so they can sync between
/// devices or back up before reinstalls. Schema version is part of the
/// payload so future clients can ignore older shapes.
struct AppSettingsSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var generatedAt: Date

    var alwaysExpandThinking: Bool
    var defaultPermissionMode: PermissionMode
    var defaultEffort: Effort

    var environments: [EnvironmentConfig]
    var customProviders: [CustomProvider]
    var modelAliases: [String: String]

    /// `"provider/modelID"` keys of models hidden from the picker (eye toggle
    /// or swipe Delete). Sorted for stable diffs.
    var hiddenModels: [String]

    var skillsRepoURL: String
    var skillsRepoBranch: String
    var mcpRepoURL: String
    var mcpRepoBranch: String

    static func empty() -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            schemaVersion: currentSchemaVersion,
            generatedAt: Date(),
            alwaysExpandThinking: false,
            defaultPermissionMode: .acceptEdits,
            defaultEffort: .high,
            environments: [],
            customProviders: [],
            modelAliases: [:],
            hiddenModels: [],
            skillsRepoURL: "",
            skillsRepoBranch: "main",
            mcpRepoURL: "",
            mcpRepoBranch: "main"
        )
    }

    init(
        schemaVersion: Int,
        generatedAt: Date,
        alwaysExpandThinking: Bool,
        defaultPermissionMode: PermissionMode,
        defaultEffort: Effort,
        environments: [EnvironmentConfig],
        customProviders: [CustomProvider],
        modelAliases: [String: String],
        hiddenModels: [String],
        skillsRepoURL: String,
        skillsRepoBranch: String,
        mcpRepoURL: String,
        mcpRepoBranch: String
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.alwaysExpandThinking = alwaysExpandThinking
        self.defaultPermissionMode = defaultPermissionMode
        self.defaultEffort = defaultEffort
        self.environments = environments
        self.customProviders = customProviders
        self.modelAliases = modelAliases
        self.hiddenModels = hiddenModels
        self.skillsRepoURL = skillsRepoURL
        self.skillsRepoBranch = skillsRepoBranch
        self.mcpRepoURL = mcpRepoURL
        self.mcpRepoBranch = mcpRepoBranch
    }

    /// Older snapshots predate some fields (hidden models, skill/MCP repo URLs);
    /// decode missing keys to sane defaults so v1 backups still restore.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        alwaysExpandThinking = try c.decode(Bool.self, forKey: .alwaysExpandThinking)
        defaultPermissionMode = try c.decode(PermissionMode.self, forKey: .defaultPermissionMode)
        defaultEffort = try c.decode(Effort.self, forKey: .defaultEffort)
        environments = try c.decode([EnvironmentConfig].self, forKey: .environments)
        customProviders = try c.decode([CustomProvider].self, forKey: .customProviders)
        modelAliases = try c.decode([String: String].self, forKey: .modelAliases)
        hiddenModels = try c.decodeIfPresent([String].self, forKey: .hiddenModels) ?? []
        skillsRepoURL = try c.decodeIfPresent(String.self, forKey: .skillsRepoURL) ?? ""
        skillsRepoBranch = try c.decodeIfPresent(String.self, forKey: .skillsRepoBranch) ?? "main"
        mcpRepoURL = try c.decodeIfPresent(String.self, forKey: .mcpRepoURL) ?? ""
        mcpRepoBranch = try c.decodeIfPresent(String.self, forKey: .mcpRepoBranch) ?? "main"
    }
}

/// Cross-device memory entries (Settings → Memory). The same `UserMemoryStore.Entry`
/// type is used on-device and on the wire; we wrap it with a schema version
/// + timestamp so future clients can tell old backups apart.
struct MemorySnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generatedAt: Date
    var entries: [UserMemoryStore.Entry]

    static func empty() -> MemorySnapshot {
        MemorySnapshot(
            schemaVersion: currentSchemaVersion,
            generatedAt: Date(),
            entries: []
        )
    }

    init(schemaVersion: Int = MemorySnapshot.currentSchemaVersion,
         generatedAt: Date = Date(),
         entries: [UserMemoryStore.Entry]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        entries = try c.decode([UserMemoryStore.Entry].self, forKey: .entries)
    }
}

/// Cross-device chat history. We send three files for clean diffs and partial
/// restore (recents / projects / project chats). Incognito chats are filtered
/// out by the caller before snapshot — their lifetime is "local only" by
/// product definition.
struct ChatsSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generatedAt: Date

    /// Sidebar Recents. Full transcript per chat (`messages: [PersistedChatMessage]`).
    var recents: [ChatHistoryItem]
    /// Projects list (project metadata only, not their chats).
    var projects: [ProjectItem]
    /// Map of project.id → its chat rows. Stored as `[UUID: ...]` for type
    /// safety in the rest of the app; serialized to disk as
    /// `[String: ...]` via `init(from:)` / `encode(to:)`.
    var projectChats: [UUID: [ProjectChatItem]]

    static func empty() -> ChatsSnapshot {
        ChatsSnapshot(
            schemaVersion: currentSchemaVersion,
            generatedAt: Date(),
            recents: [],
            projects: [],
            projectChats: [:]
        )
    }

    init(schemaVersion: Int = ChatsSnapshot.currentSchemaVersion,
         generatedAt: Date = Date(),
         recents: [ChatHistoryItem],
         projects: [ProjectItem],
         projectChats: [UUID: [ProjectChatItem]]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.recents = recents
        self.projects = projects
        self.projectChats = projectChats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        recents = try c.decode([ChatHistoryItem].self, forKey: .recents)
        projects = try c.decode([ProjectItem].self, forKey: .projects)
        let raw: [String: [ProjectChatItem]] = (try c.decodeIfPresent(
            [String: [ProjectChatItem]].self, forKey: .projectChats
        )) ?? [:]
        var mapped: [UUID: [ProjectChatItem]] = [:]
        for (key, value) in raw {
            if let uuid = UUID(uuidString: key) {
                mapped[uuid] = value
            }
        }
        projectChats = mapped
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(recents, forKey: .recents)
        try c.encode(projects, forKey: .projects)
        var stringKeyed: [String: [ProjectChatItem]] = [:]
        for (key, value) in projectChats {
            stringKeyed[key.uuidString] = value
        }
        try c.encode(stringKeyed, forKey: .projectChats)
    }

    /// Stored properties get serialized as these keys. Explicit because we
    /// override both `init(from:)` and `encode(to:)` for the UUID→String
    /// projectChats mapping.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case recents
        case projects
        case projectChats
    }
}

/// Pushes and pulls `AppSettingsSnapshot` (settings.json), `MemorySnapshot`
/// (memory.json) and `ChatsSnapshot` (chats/recents.json, chats/projects.json,
/// chats/project-chats.json) to a GitHub repo. Uses the existing GitHub PAT
/// stored in the keychain; no desktop involvement.
actor SettingsSync {
    static let repoName = "anyprov-code-settings"

    /// Files this sync writes — keep in sync with `SyncKind` below.
    static let paths = SyncKind.allPaths
    static let filePath = "settings.json"

    /// Each file in the sync gets a `SyncKind` so the push/pull UI can show
    /// per-file status (e.g. "memory synced" vs. "chats: no changes").
    enum SyncKind: String, CaseIterable, Sendable {
        case settings
        case memory
        case recents
        case projects
        case projectChats

        var displayName: String {
            switch self {
            case .settings: return "Settings"
            case .memory: return "Memory"
            case .recents: return "Recents"
            case .projects: return "Projects"
            case .projectChats: return "Project chats"
            }
        }

        /// File path inside the sync repo.
        var path: String {
            switch self {
            case .settings: return "settings.json"
            case .memory: return "memory.json"
            case .recents: return "chats/recents.json"
            case .projects: return "chats/projects.json"
            case .projectChats: return "chats/project-chats.json"
            }
        }

        static var allPaths: [String] { allCases.map { $0.path } }
    }

    enum SyncError: Error, LocalizedError {
        case noGitHubToken
        case noRepo
        case gitHubError(Error)

        var errorDescription: String? {
            switch self {
            case .noGitHubToken: return "Link your GitHub account in Settings first."
            case .noRepo: return "Set a settings-sync repo in Settings."
            case let .gitHubError(err): return err.localizedDescription
            }
        }
    }

    private let client: GitHubClient

    init(client: GitHubClient = GitHubClient(clientID: "")) {
        self.client = client
    }

    /// Returns `true` if the repo already exists, `false` otherwise.
    func ensureRepo(token: String) async throws -> GitHubRepo {
        let user = try await client.currentUser(token: token)
        let fullName = "\(user.login)/\(Self.repoName)"
        if try await client.repoExists(token: token, fullName: fullName) {
            // Repo exists — look it up so we can return its metadata.
            return try await client.listRepos(token: token)
                .first(where: { $0.fullName == fullName })
                ?? GitHubRepo(
                    fullName: fullName,
                    name: Self.repoName,
                    owner: user.login,
                    isPrivate: true,
                    defaultBranch: "main",
                    pushedAt: nil
                )
        }
        return try await client.createRepo(
            token: token,
            name: Self.repoName,
            description: "Synced data for anyprov-code (settings, memory, chat history).",
            isPrivate: true,
            autoInit: true
        )
    }

    // MARK: - Settings push/pull (back-compat with existing call sites)

    /// Push the snapshot, creating the file on the first call.
    func push(snapshot: AppSettingsSnapshot, token: String, repoFullName: String) async throws {
        let content = try encodeJSON(snapshot)
        try await pushFile(kind: .settings, token: token, repoFullName: repoFullName, content: content)
    }

    /// Pull the snapshot, returning nil if the file doesn't exist yet.
    func pull(token: String, repoFullName: String) async throws -> AppSettingsSnapshot? {
        try await pullDecoded(kind: .settings, token: token, repoFullName: repoFullName)
    }

    // MARK: - Memory push/pull

    func push(memory: MemorySnapshot, token: String, repoFullName: String) async throws {
        let content = try encodeJSON(memory)
        try await pushFile(kind: .memory, token: token, repoFullName: repoFullName, content: content)
    }

    func pullMemory(token: String, repoFullName: String) async throws -> MemorySnapshot? {
        try await pullDecoded(kind: .memory, token: token, repoFullName: repoFullName)
    }

    // MARK: - Chats push/pull

    /// Push all three chat files. We push them in a stable order and reuse
    /// each file's previous `sha` so GitHub tracks them as updates, not
    /// duplicate creates.
    func push(chats: ChatsSnapshot, token: String, repoFullName: String) async throws {
        let recentsContent = try encodeJSON(ChatsRecentsFile(snapshot: chats))
        let projectsContent = try encodeJSON(ChatsProjectsFile(snapshot: chats))
        let projectChatsContent = try encodeJSON(ChatsProjectChatsFile(snapshot: chats))

        try await pushFile(kind: .recents, token: token, repoFullName: repoFullName, content: recentsContent)
        try await pushFile(kind: .projects, token: token, repoFullName: repoFullName, content: projectsContent)
        try await pushFile(kind: .projectChats, token: token, repoFullName: repoFullName, content: projectChatsContent)
    }

    /// Pull all three chat files. Missing files come back as `nil` (e.g.
    /// very first pull before any chats were ever pushed).
    func pullChats(token: String, repoFullName: String) async throws -> ChatsSnapshot {
        let recentsFile: ChatsRecentsFile? = try? await pullDecoded(
            kind: .recents, token: token, repoFullName: repoFullName
        )
        let projectsFile: ChatsProjectsFile? = try? await pullDecoded(
            kind: .projects, token: token, repoFullName: repoFullName
        )
        let projectChatsFile: ChatsProjectChatsFile? = try? await pullDecoded(
            kind: .projectChats, token: token, repoFullName: repoFullName
        )
        let rawProjectChats = projectChatsFile?.projectChats ?? [:]
        var mappedProjectChats: [UUID: [ProjectChatItem]] = [:]
        for (key, value) in rawProjectChats {
            if let uuid = UUID(uuidString: key) {
                mappedProjectChats[uuid] = value
            }
        }
        return ChatsSnapshot(
            recents: recentsFile?.recents ?? [],
            projects: projectsFile?.projects ?? [],
            projectChats: mappedProjectChats
        )
    }

    // MARK: - Generic per-file push/pull helpers

    private func pushFile(
        kind: SyncKind,
        token: String,
        repoFullName: String,
        content: String
    ) async throws {
        let existing = try? await client.getFile(
            token: token,
            fullName: repoFullName,
            path: kind.path
        )
        do {
            try await client.putFile(
                token: token,
                fullName: repoFullName,
                path: kind.path,
                message: commitMessage(for: kind),
                content: content,
                sha: existing?.sha
            )
        } catch {
            throw SyncError.gitHubError(error)
        }
    }

    private func pullDecoded<T: Decodable>(
        kind: SyncKind,
        token: String,
        repoFullName: String
    ) async throws -> T? {
        guard let file = try await client.getFile(
            token: token,
            fullName: repoFullName,
            path: kind.path
        ) else { return nil }
        guard let data = Data(base64Encoded: file.content
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func commitMessage(for kind: SyncKind) -> String {
        switch kind {
        case .settings: return "chore: sync anyprov-code settings"
        case .memory: return "chore: sync anyprov-code memory"
        case .recents: return "chore: sync anyprov-code chat recents"
        case .projects: return "chore: sync anyprov-code projects"
        case .projectChats: return "chore: sync anyprov-code project chats"
        }
    }
}

// MARK: - Per-file chat wrappers

/// `ChatsSnapshot` is one logical thing but lives as three files. Each file
/// gets its own envelope so a single bad file doesn't poison the others.
private struct ChatsRecentsFile: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = ChatsRecentsFile.currentSchemaVersion
    var generatedAt: Date
    var recents: [ChatHistoryItem]

    init(snapshot: ChatsSnapshot) {
        generatedAt = snapshot.generatedAt
        recents = snapshot.recents
    }
}

private struct ChatsProjectsFile: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = ChatsProjectsFile.currentSchemaVersion
    var generatedAt: Date
    var projects: [ProjectItem]

    init(snapshot: ChatsSnapshot) {
        generatedAt = snapshot.generatedAt
        projects = snapshot.projects
    }
}

private struct ChatsProjectChatsFile: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = ChatsProjectChatsFile.currentSchemaVersion
    var generatedAt: Date
    var projectChats: [String: [ProjectChatItem]]

    init(snapshot: ChatsSnapshot) {
        generatedAt = snapshot.generatedAt
        var out: [String: [ProjectChatItem]] = [:]
        for (key, value) in snapshot.projectChats {
            out[key.uuidString] = value
        }
        projectChats = out
    }
}

// MARK: - Dictionary key conversion helpers

private extension Dictionary {
    func mapKeys<K: Hashable>(_ transform: (Key) -> K) -> [K: Value] {
        var out: [K: Value] = [:]
        out.reserveCapacity(count)
        for (k, v) in self { out[transform(k)] = v }
        return out
    }

    func compactMapKeys<K: Hashable>(_ transform: (Key) -> K?) -> [K: Value] {
        var out: [K: Value] = [:]
        out.reserveCapacity(count)
        for (k, v) in self {
            if let nk = transform(k) { out[nk] = v }
        }
        return out
    }
}