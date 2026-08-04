import Foundation
import MobileAICore

/// Everything needed to open a coding session, passed to `SessionView`.
struct SessionConfig: Identifiable, Hashable {
    let id = UUID()
    let endpoint: ServerClient.Endpoint
    let token: String
    let repo: RepoRef
    let environment: EnvironmentConfig?
    let model: ModelSelection
    let permissionMode: PermissionMode
    let firstMessage: String
    let skills: [String]
    let mcpServers: [MCPServerConfig]

    // Identity is the generated id; other fields aren't all Hashable.
    static func == (lhs: SessionConfig, rhs: SessionConfig) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
