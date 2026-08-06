import Foundation
import AnyProvCore

/// Everything needed to open a coding session, passed to `SessionView`.
struct SessionConfig: Identifiable, Hashable {
    /// Local SwiftUI navigation identity.
    let id: UUID
    /// Wire protocol session id (shared with desktop SessionManager / tools).
    let wireSessionId: String
    /// Persisted Code home row id, when opened from history.
    let localSessionId: UUID?
    let endpoint: ServerClient.Endpoint
    let token: String
    let repo: RepoRef
    let environment: EnvironmentConfig?
    let model: ModelSelection
    let permissionMode: PermissionMode
    let firstMessage: String
    let skills: [String]
    let mcpServers: [MCPServerConfig]
    /// When true, reconnect without re-sending the original first message.
    let resuming: Bool
    /// Known PR / compare URL for this session, if any.
    let prURL: String?

    init(
        id: UUID = UUID(),
        wireSessionId: String = "s_\(UUID().uuidString.prefix(8).lowercased())",
        localSessionId: UUID? = nil,
        endpoint: ServerClient.Endpoint,
        token: String,
        repo: RepoRef,
        environment: EnvironmentConfig?,
        model: ModelSelection,
        permissionMode: PermissionMode,
        firstMessage: String,
        skills: [String],
        mcpServers: [MCPServerConfig],
        resuming: Bool = false,
        prURL: String? = nil
    ) {
        self.id = id
        self.wireSessionId = wireSessionId
        self.localSessionId = localSessionId
        self.endpoint = endpoint
        self.token = token
        self.repo = repo
        self.environment = environment
        self.model = model
        self.permissionMode = permissionMode
        self.firstMessage = firstMessage
        self.skills = skills
        self.mcpServers = mcpServers
        self.resuming = resuming
        self.prURL = prURL
    }

    static func == (lhs: SessionConfig, rhs: SessionConfig) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
