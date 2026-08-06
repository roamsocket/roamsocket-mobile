import Foundation

/// Errors emitted by skills/MCP sync over WebSocket.
public enum SkillsMCPError: Error, LocalizedError {
    case noServer
    case serverError(String)
    case decodeFailure

    public var errorDescription: String? {
        switch self {
        case .noServer: return "Not paired with a desktop server."
        case let .serverError(msg): return msg
        case .decodeFailure: return "Server returned malformed data."
        }
    }
}

/// iOS-side stub for the skills/MCP sync client. The real git work happens
/// on the desktop server (which has `git` in PATH and a real filesystem);
/// this class sends upsert/delete/sync requests over the WebSocket and
/// surfaces server-side errors.
///
/// iOS keeps a local JSON cache of the latest synced state for offline
/// viewing; edits go through `ServerClient.send(...)` with one of the
/// `SkillsMCPMessage` types below.
public final class SkillsMCPClient: ObservableObject, @unchecked Sendable {
    @Published public private(set) var lastSyncError: String?

    /// Local cache of skills (mirrors the last `skills_sync` from desktop).
    @Published public private(set) var cachedSkills: [Skill] = []
    /// Local cache of MCP servers (mirrors the last `mcp_sync` from desktop).
    @Published public private(set) var cachedMCPServers: [MCPServer] = []

    private let skillsCacheKey = "skillsMCP.skillsCache.v1"
    private let mcpCacheKey = "skillsMCP.mcpCache.v1"

    public init() {
        loadCaches()
    }

    public func handleServerMessage(_ message: ServerMessage) {
        switch message {
        case let .skillsSync(skills):
            cachedSkills = skills
            saveCaches()
        case let .mcpSync(servers):
            cachedMCPServers = servers.map { entry in
                MCPServer(
                    id: entry.id,
                    name: entry.name,
                    description: entry.description ?? "",
                    command: entry.command ?? "",
                    args: entry.args ?? [],
                    env: entry.env ?? [:],
                    isEnabled: entry.isEnabled ?? true
                )
            }
            saveCaches()
        default:
            break
        }
    }

    // MARK: - Outgoing ops (routed via the active `ServerClient`)

    /// Ask the desktop to pull + push the configured skills repo and resync.
    public func requestSkillsSync(over client: ServerClient) async throws {
        try await client.send(.skillsSyncRequest)
    }

    /// Ask the desktop to pull + push the configured MCP repo and resync.
    public func requestMCPSync(over client: ServerClient) async throws {
        try await client.send(.mcpSyncRequest)
    }

    /// Upsert a skill via the desktop. The server replies with a fresh
    /// `skills_sync` that the caller wires into the `SkillManager` via
    /// `apply(skills:)`. We also update the local cache eagerly so the
    /// list view reflects the change immediately.
    public func upsertSkill(_ skill: Skill, over client: ServerClient) async throws {
        if let idx = cachedSkills.firstIndex(where: { $0.id == skill.id }) {
            var merged = skill
            merged.isEnabled = cachedSkills[idx].isEnabled
            cachedSkills[idx] = merged
        } else {
            var copy = skill
            copy.isEnabled = true
            cachedSkills.insert(copy, at: 0)
        }
        saveCaches()
        try await client.send(.skillUpsert(skill: skill))
    }

    /// Delete a skill via the desktop. Local cache is updated eagerly.
    public func deleteSkill(id: String, over client: ServerClient) async throws {
        cachedSkills.removeAll { $0.id == id }
        saveCaches()
        try await client.send(.skillDelete(id: id))
    }

    /// Upsert an MCP server via the desktop.
    public func upsertMCPServer(_ server: MCPServer, over client: ServerClient) async throws {
        if let idx = cachedMCPServers.firstIndex(where: { $0.id == server.id }) {
            var merged = server
            merged.isEnabled = cachedMCPServers[idx].isEnabled
            cachedMCPServers[idx] = merged
        } else {
            var copy = server
            copy.isEnabled = true
            cachedMCPServers.insert(copy, at: 0)
        }
        saveCaches()
        try await client.send(.mcpUpsert(server: server))
    }

    /// Delete an MCP server via the desktop.
    public func deleteMCPServer(id: String, over client: ServerClient) async throws {
        cachedMCPServers.removeAll { $0.id == id }
        saveCaches()
        try await client.send(.mcpDelete(id: id))
    }

    /// Ask the desktop for the canonical state and refresh the local caches.
    /// Used when entering Settings / on app foreground so the user always
    /// sees the most up-to-date list even before they start a session.
    public func refreshAll(over client: ServerClient) async {
        try? await client.send(.skillsSyncRequest)
        try? await client.send(.mcpSyncRequest)
    }

    // MARK: - Local cache (offline view)

    private func loadCaches() {
        if let data = UserDefaults.standard.data(forKey: skillsCacheKey),
           let decoded = try? JSONDecoder().decode([Skill].self, from: data) {
            cachedSkills = decoded
        }
        if let data = UserDefaults.standard.data(forKey: mcpCacheKey),
           let decoded = try? JSONDecoder().decode([MCPServer].self, from: data) {
            cachedMCPServers = decoded
        }
    }

    private func saveCaches() {
        if let data = try? JSONEncoder().encode(cachedSkills) {
            UserDefaults.standard.set(data, forKey: skillsCacheKey)
        }
        if let data = try? JSONEncoder().encode(cachedMCPServers) {
            UserDefaults.standard.set(data, forKey: mcpCacheKey)
        }
    }
}
