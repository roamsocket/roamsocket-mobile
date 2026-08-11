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

/// iOS client for skills/MCP sync. Git work runs on the paired desktop
/// (filesystem + `git`); this type sends upsert/delete/sync over WebSocket
/// and surfaces server errors.
///
/// Local JSON cache holds the latest synced state for offline viewing; edits
/// go through `ServerClient.send(...)` with the skills/MCP message types.
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
            cachedMCPServers = servers
            saveCaches()
        default:
            break
        }
    }

    // MARK: - Outgoing ops (self-connecting)

    /// Ask the desktop to pull + push the configured skills repo and resync.
    public func requestSkillsSync(endpoint: ServerClient.Endpoint, token: String) async throws {
        try await performOp(.skillsSyncRequest, kind: .skills, endpoint: endpoint, token: token)
    }

    /// Ask the desktop to pull + push the configured MCP repo and resync.
    public func requestMCPSync(endpoint: ServerClient.Endpoint, token: String) async throws {
        try await performOp(.mcpSyncRequest, kind: .mcp, endpoint: endpoint, token: token)
    }

    /// Upsert a skill via the desktop. The server replies with a fresh
    /// `skills_sync` that we apply to the local cache (and the caller applies
    /// to `SkillManager`). The local cache is updated eagerly so the list
    /// reflects the change immediately.
    public func upsertSkill(
        _ skill: Skill,
        endpoint: ServerClient.Endpoint,
        token: String
    ) async throws {
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
        try await performOp(.skillUpsert(skill: skill), kind: .skills, endpoint: endpoint, token: token)
    }

    /// Delete a skill via the desktop. Local cache is updated eagerly.
    public func deleteSkill(
        id: String,
        endpoint: ServerClient.Endpoint,
        token: String
    ) async throws {
        cachedSkills.removeAll { $0.id == id }
        saveCaches()
        try await performOp(.skillDelete(id: id), kind: .skills, endpoint: endpoint, token: token)
    }

    /// Upsert an MCP server via the desktop.
    public func upsertMCPServer(
        _ server: MCPServer,
        endpoint: ServerClient.Endpoint,
        token: String
    ) async throws {
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
        try await performOp(.mcpUpsert(server: server), kind: .mcp, endpoint: endpoint, token: token)
    }

    /// Delete an MCP server via the desktop.
    public func deleteMCPServer(
        id: String,
        endpoint: ServerClient.Endpoint,
        token: String
    ) async throws {
        cachedMCPServers.removeAll { $0.id == id }
        saveCaches()
        try await performOp(.mcpDelete(id: id), kind: .mcp, endpoint: endpoint, token: token)
    }

    /// Ask the desktop for the canonical state and refresh the local caches.
    /// Used when entering Settings / Connectors so the user always sees the
    /// most up-to-date list even before they start a session. Errors (e.g. no
    /// repo configured) are surfaced via `lastSyncError`, not thrown.
    public func refreshAll(
        endpoint: ServerClient.Endpoint,
        token: String,
        timeoutSeconds: TimeInterval = 10
    ) async {
        lastSyncError = nil
        do {
            try await requestSkillsSync(endpoint: endpoint, token: token)
        } catch {
            lastSyncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        do {
            try await requestMCPSync(endpoint: endpoint, token: token)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if lastSyncError == nil { lastSyncError = message }
        }
    }

    /// The app's long-lived socket only exists inside a coding session, so
    /// every skills/MCP op opens its own short-lived connection, waits for the
    /// desktop's acknowledging sync (or error), then tears down.
    private func performOp(
        _ request: ClientMessage,
        kind: SyncKind,
        endpoint: ServerClient.Endpoint,
        token: String,
        timeoutSeconds: TimeInterval = 15
    ) async throws {
        let client = ServerClient()
        var opError: Error = SkillsMCPError.serverError("Desktop did not acknowledge the request.")
        do {
            let stream = try await client.connect(endpoint: endpoint, token: token)
            try await client.send(request)
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            for await message in stream {
                switch message {
                case .skillsSync where kind == .skills:
                    handleServerMessage(message)
                    await client.disconnect()
                    return
                case .mcpSync where kind == .mcp:
                    handleServerMessage(message)
                    await client.disconnect()
                    return
                case let .error(_, text):
                    opError = SkillsMCPError.serverError(
                        text.isEmpty ? "Desktop sync failed." : text
                    )
                default:
                    break
                }
                if Date() > deadline { break }
            }
            await client.disconnect()
        } catch {
            opError = error
        }
        throw opError
    }

    private enum SyncKind {
        case skills
        case mcp
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
