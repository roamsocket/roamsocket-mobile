import Foundation
import AnyProvCore

/// Snapshot of the iOS app's user settings, written to a GitHub repo the
/// user owns (default: `anyprov-code-settings`) so they can sync between
/// devices or back up before reinstalls. Schema version is part of the
/// payload so future clients can ignore older shapes.
struct AppSettingsSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generatedAt: Date

    var alwaysExpandThinking: Bool
    var defaultPermissionMode: PermissionMode
    var defaultEffort: Effort

    var environments: [EnvironmentConfig]
    var customProviders: [CustomProvider]
    var modelAliases: [String: String]

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
            skillsRepoURL: "",
            skillsRepoBranch: "main",
            mcpRepoURL: "",
            mcpRepoBranch: "main"
        )
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