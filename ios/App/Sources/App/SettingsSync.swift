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

/// Pushes and pulls `AppSettingsSnapshot` to a GitHub repo. Uses the
/// existing GitHub PAT stored in the keychain; no desktop involvement.
actor SettingsSync {
    static let repoName = "anyprov-code-settings"
    static let filePath = "settings.json"

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
            description: "Synced settings for anyprov-code (environments, model aliases, custom providers).",
            isPrivate: true,
            autoInit: true
        )
    }

    /// Push the snapshot, creating the file on the first call.
    func push(snapshot: AppSettingsSnapshot, token: String, repoFullName: String) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        let content = String(data: data, encoding: .utf8) ?? "{}"
        let existing = try? await client.getFile(
            token: token,
            fullName: repoFullName,
            path: Self.filePath
        )
        do {
            try await client.putFile(
                token: token,
                fullName: repoFullName,
                path: Self.filePath,
                message: "chore: sync anyprov-code settings",
                content: content,
                sha: existing?.sha
            )
        } catch {
            throw SyncError.gitHubError(error)
        }
    }

    /// Pull the snapshot, returning nil if the file doesn't exist yet.
    func pull(token: String, repoFullName: String) async throws -> AppSettingsSnapshot? {
        guard let file = try await client.getFile(
            token: token,
            fullName: repoFullName,
            path: Self.filePath
        ) else { return nil }
        guard let data = Data(base64Encoded: file.content
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppSettingsSnapshot.self, from: data)
    }
}