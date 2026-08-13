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

/// In-memory snapshot of all chats to sync. On the wire this is split into
/// one file per chat plus `chats/projects.json`; the struct itself is just
/// a convenience container for the push/pull APIs. Incognito chats are
/// filtered out by the caller before snapshot — their lifetime is "local
/// only" by product definition.
struct ChatsSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var generatedAt: Date

    /// Sidebar Recents. Full transcript per chat (`messages: [PersistedChatMessage]`).
    var recents: [ChatHistoryItem]
    /// Projects list (project metadata only, not their chats).
    var projects: [ProjectItem]
    /// Map of project.id → its chat rows.
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
}

/// Pushes and pulls `AppSettingsSnapshot` (settings.json), `MemorySnapshot`
/// (memory.json) and chat history (one file per chat:
/// `chats/recents/<id>.json` + `chats/project-chats/<id>.json`, plus
/// `chats/projects.json`) to a GitHub repo. Uses the existing GitHub PAT
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

        /// File path inside the sync repo. Single-file kinds have a stable path;
/// per-chat kinds return their directory prefix — the actual file lives at
/// `directoryPrefix + "/" + chatID.uuidString + ".json"`.
        var path: String {
            switch self {
            case .settings: return "settings.json"
            case .memory: return "memory.json"
            case .recents: return "chats/recents"
            case .projects: return "chats/projects.json"
            case .projectChats: return "chats/project-chats"
            }
        }

        /// Full path for a single chat (recents or project chats).
        func path(forChatID id: UUID) -> String {
            "\(path)/\(id.uuidString).json"
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
        try await pushFile(
            path: SettingsSync.SyncKind.settings.path,
            token: token,
            repoFullName: repoFullName,
            content: content,
            commitMessage: Self.commitMessage(for: .settings)
        )
    }

    /// Pull the snapshot, returning nil if the file doesn't exist yet.
    func pull(token: String, repoFullName: String) async throws -> AppSettingsSnapshot? {
        try await pullDecoded(
            path: SettingsSync.SyncKind.settings.path,
            token: token,
            repoFullName: repoFullName
        )
    }

    // MARK: - Memory push/pull

    func push(memory: MemorySnapshot, token: String, repoFullName: String) async throws {
        let content = try encodeJSON(memory)
        try await pushFile(
            path: SettingsSync.SyncKind.memory.path,
            token: token,
            repoFullName: repoFullName,
            content: content,
            commitMessage: Self.commitMessage(for: .memory)
        )
    }

    func pullMemory(token: String, repoFullName: String) async throws -> MemorySnapshot? {
        try await pullDecoded(
            path: SettingsSync.SyncKind.memory.path,
            token: token,
            repoFullName: repoFullName
        )
    }

    // MARK: - Chats push/pull

    /// Push chats: one file per recent chat and one file per project chat,
    /// plus a single `chats/projects.json`. We push each file with its
    /// previous `sha` so GitHub tracks them as updates, not duplicate
    /// creates. Recents are pushed newest-first so the most active chat
    /// appears first in the git history.
    func push(chats: ChatsSnapshot, token: String, repoFullName: String) async throws {
        // Projects first — single file, stable.
        let projectsContent = try encodeJSON(ChatsProjectsFile(snapshot: chats))
        try await pushFile(
            path: SettingsSync.SyncKind.projects.path,
            token: token,
            repoFullName: repoFullName,
            content: projectsContent,
            commitMessage: Self.commitMessage(for: .projects)
        )

        // Recents — one file per chat, sorted newest-first.
        let sortedRecents = chats.recents.sorted { $0.lastMessageAt > $1.lastMessageAt }
        for chat in sortedRecents {
            let envelope = ChatsRecentsFileEnvelope(generatedAt: chats.generatedAt, chat: chat)
            let content = try encodeJSON(envelope)
            try await pushFile(
                path: SettingsSync.SyncKind.recents.path(forChatID: chat.id),
                token: token,
                repoFullName: repoFullName,
                content: content,
                commitMessage: Self.commitMessage(for: .recents)
            )
        }

        // Project chats — one file per chat (flat), regardless of which
        // project the chat belongs to.
        let flattened = chats.projectChats.flatMap { (projectID, rows) in
            rows.map { (projectID, $0) }
        }
        let sortedProjectChats = flattened.sorted { $0.1.lastMessageAt > $1.1.lastMessageAt }
        for (projectID, chat) in sortedProjectChats {
            let envelope = ChatsProjectChatsFileEnvelope(
                generatedAt: chats.generatedAt,
                projectID: projectID,
                chat: chat
            )
            let content = try encodeJSON(envelope)
            try await pushFile(
                path: SettingsSync.SyncKind.projectChats.path(forChatID: chat.id),
                token: token,
                repoFullName: repoFullName,
                content: content,
                commitMessage: Self.commitMessage(for: .projectChats)
            )
        }
    }

    /// Pull chats: enumerate per-id files via the GitHub Contents API, and
    /// for backward compatibility also read the legacy aggregate files
    /// (`chats/recents.json` and `chats/project-chats.json`) when they
    /// still exist. Legacy wins for chats it lists; per-id wins for chats
    /// the legacy doesn't know about. After the first per-id push, legacy
    /// is stale and the per-id layer carries the truth forward.
    func pullChats(token: String, repoFullName: String) async throws -> ChatsSnapshot {
        // Projects — single file (not per-id in this design).
        let projectsFile: ChatsProjectsFile? = try? await pullDecoded(
            path: SettingsSync.SyncKind.projects.path,
            token: token,
            repoFullName: repoFullName
        )

        // Recents: merge legacy aggregate + per-id files.
        let recents = await pullRecentChats(
            legacyAggregatePath: "chats/recents.json",
            token: token,
            repoFullName: repoFullName
        )

        // Project chats: same.
        let projectChats = await pullAllProjectChats(
            legacyAggregatePath: "chats/project-chats.json",
            token: token,
            repoFullName: repoFullName
        )

        return ChatsSnapshot(
            recents: recents,
            projects: projectsFile?.projects ?? [],
            projectChats: projectChats
        )
    }

    /// Merges the legacy aggregate and every per-id recents file. Per-id
    /// wins on id conflict (newer shape is the source of truth post-
    /// migration); legacy fills in any ids the per-id layer is missing.
    private func pullRecentChats(
        legacyAggregatePath: String,
        token: String,
        repoFullName: String
    ) async -> [ChatHistoryItem] {
        // 1. Pull legacy aggregate if present.
        var merged: [UUID: ChatHistoryItem] = [:]
        if let legacy: ChatsRecentsFile = try? await pullDecoded(
            path: legacyAggregatePath,
            token: token,
            repoFullName: repoFullName
        ) {
            for chat in legacy.recents {
                merged[chat.id] = chat
            }
        }

        // 2. Enumerate `chats/recents/` and read each per-id file. Per-id
        //    wins because it's the new shape the device is actively writing.
        let entries = (try? await client.listDirectory(
            token: token,
            fullName: repoFullName,
            path: SettingsSync.SyncKind.recents.path
        )) ?? []
        for entry in entries where entry.type == "file" && entry.name.hasSuffix(".json") {
            let idString = String(entry.name.dropLast(".json".count))
            guard let id = UUID(uuidString: idString) else { continue }
            let envelope: ChatsRecentsFileEnvelope? = try? await pullDecoded(
                path: entry.path,
                token: token,
                repoFullName: repoFullName
            )
            if let chat = envelope?.chat {
                merged[id] = chat
            }
        }

        return Array(merged.values)
    }

    /// Same merge logic for project chats. Legacy aggregate keyed by
    /// projectID (string on disk); per-id files are flat (projectChatItem
    /// already carries its projectID). We use the per-id file's
    /// `chat.projectID` to bucket the result into `[UUID: [ProjectChatItem]]`
    /// for the caller.
    private func pullAllProjectChats(
        legacyAggregatePath: String,
        token: String,
        repoFullName: String
    ) async -> [UUID: [ProjectChatItem]] {
        // 1. Legacy aggregate.
        var byProject: [UUID: [ProjectChatItem]] = [:]
        if let legacy: ChatsProjectChatsFile = try? await pullDecoded(
            path: legacyAggregatePath,
            token: token,
            repoFullName: repoFullName
        ) {
            for (key, rows) in legacy.projectChats {
                guard let pid = UUID(uuidString: key) else { continue }
                byProject[pid] = rows
            }
        }

        // 2. Per-id files.
        let entries = (try? await client.listDirectory(
            token: token,
            fullName: repoFullName,
            path: SettingsSync.SyncKind.projectChats.path
        )) ?? []
        // Build a quick lookup keyed by chat id so we can replace legacy rows.
        var flat: [UUID: (UUID, ProjectChatItem)] = [:]
        for entry in entries where entry.type == "file" && entry.name.hasSuffix(".json") {
            let idString = String(entry.name.dropLast(".json".count))
            guard let id = UUID(uuidString: idString) else { continue }
            let envelope: ChatsProjectChatsFileEnvelope? = try? await pullDecoded(
                path: entry.path,
                token: token,
                repoFullName: repoFullName
            )
            if let envelope {
                flat[id] = (envelope.projectID, envelope.chat)
            }
        }

        // Re-bucket: for each chat id, prefer the per-id version. If only
        // legacy exists, fall back to the legacy bucket.
        var out: [UUID: [ProjectChatItem]] = [:]
        // First, lay down everything legacy had.
        for (pid, rows) in byProject {
            out[pid] = rows
        }
        // Then overwrite/add per-id rows. Per-id carries its own projectID
        // (in the envelope) since `ProjectChatItem` doesn't have one.
        for (_, projectIDAndChat) in flat {
            let (pid, chat) = projectIDAndChat
            out[pid, default: []].append(chat)
        }
        return out
    }

    // MARK: - Generic per-file push/pull helpers

    /// Push a single file by path (no `SyncKind` — per-chat files use this).
    private func pushFile(
        path: String,
        token: String,
        repoFullName: String,
        content: String,
        commitMessage: String
    ) async throws {
        let existing = try? await client.getFile(
            token: token,
            fullName: repoFullName,
            path: path
        )
        do {
            try await client.putFile(
                token: token,
                fullName: repoFullName,
                path: path,
                message: commitMessage,
                content: content,
                sha: existing?.sha
            )
        } catch {
            throw SyncError.gitHubError(error)
        }
    }

    private func pullDecoded<T: Decodable>(
        path: String,
        token: String,
        repoFullName: String
    ) async throws -> T? {
        guard let file = try await client.getFile(
            token: token,
            fullName: repoFullName,
            path: path
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

    private static func commitMessage(for kind: SyncKind) -> String {
        switch kind {
        case .settings: return "chore: sync anyprov-code settings"
        case .memory: return "chore: sync anyprov-code memory"
        case .recents: return "chore: sync anyprov-code chat recents"
        case .projects: return "chore: sync anyprov-code projects"
        case .projectChats: return "chore: sync anyprov-code project chats"
        }
    }
}

// MARK: - Per-file chat envelopes

/// `ChatsSnapshot` is one logical thing but lives as N+1 files in the repo:
/// one file per recent chat, one file per project chat, and one projects
/// file. Each per-chat file gets the same envelope (schema + generatedAt +
/// chat) so future clients can detect older shapes and a single bad file
/// can't poison the rest.
private struct ChatsRecentsFileEnvelope: Codable, Sendable {
    static let currentSchemaVersion = 2
    var schemaVersion: Int = ChatsRecentsFileEnvelope.currentSchemaVersion
    var generatedAt: Date
    var chat: ChatHistoryItem

    init(generatedAt: Date, chat: ChatHistoryItem) {
        self.generatedAt = generatedAt
        self.chat = chat
    }
}

private struct ChatsProjectChatsFileEnvelope: Codable, Sendable {
    static let currentSchemaVersion = 2
    var schemaVersion: Int = ChatsProjectChatsFileEnvelope.currentSchemaVersion
    var generatedAt: Date
    /// Project this chat belongs to. Not stored on `ProjectChatItem` (its
    /// id is the key in the local dictionary), so we keep it here for the
    /// per-id file shape — every chat file lives flat under
    /// `chats/project-chats/<chatID>.json`, and we re-bucket by `projectID`
    /// on the way back into `ChatsSnapshot`.
    var projectID: UUID
    var chat: ProjectChatItem

    init(generatedAt: Date, projectID: UUID, chat: ProjectChatItem) {
        self.generatedAt = generatedAt
        self.projectID = projectID
        self.chat = chat
    }
}

/// Projects are still a single file — they don't churn as much as chats.
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

// MARK: - Legacy aggregate envelopes (read-only)

/// Legacy v1 shape: `chats/recents.json` carried the whole recent-chats
/// list in one file. We still decode this on pull so users who upgraded
/// from the previous release keep their cross-device history until the
/// first push rewrites everything in the new per-chat shape.
private struct ChatsRecentsFile: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = ChatsRecentsFile.currentSchemaVersion
    var generatedAt: Date
    var recents: [ChatHistoryItem]
}

/// Legacy v1 shape: `chats/project-chats.json` carried every project chat
/// in one file. Read-only — we don't emit it any more.
private struct ChatsProjectChatsFile: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = ChatsProjectChatsFile.currentSchemaVersion
    var generatedAt: Date
    /// `[projectID.uuidString: [ProjectChatItem]]` on disk, kept as
    /// `[String: ...]` so the JSON parses cleanly. Decoded back to
    /// `[UUID: ...]` by `pullProjectChats`.
    var projectChats: [String: [ProjectChatItem]]
}