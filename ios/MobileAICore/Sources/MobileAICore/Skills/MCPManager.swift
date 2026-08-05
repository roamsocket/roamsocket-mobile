import Foundation

/// Manages MCP servers sourced from a git repo on the user's GitHub account.
///
/// All git operations live on the desktop (which has `git` in PATH and a
/// real filesystem). This class is the iOS view: it tracks the local cache
/// from the last `mcp_sync` push, exposes `enabledServers` for the session
/// config, and forwards edit requests over the WebSocket via `SkillsMCPClient`.
///
/// The repo URL + branch are configured on the desktop side (Settings) and
/// replicated to the app via the WebSocket `mcp_sync` payload. Nothing is
/// bundled in the app.
public final class MCPManager: ObservableObject, @unchecked Sendable {
    @Published public private(set) var configuredServers: [MCPServer] = []

    private let configuredKey = "configuredMCPServers.v1"

    public init() {
        loadConfiguredServers()
    }

    /// Apply a fresh list from the desktop (also called from the WebSocket
    /// sync handler).
    public func apply(servers: [MCPServer]) {
        // Preserve local `isEnabled` for servers that haven't been deleted.
        let enabledIds = Set(configuredServers.filter { $0.isEnabled }.map(\.id))
        configuredServers = servers.map { server in
            var copy = server
            copy.isEnabled = enabledIds.contains(server.id)
            return copy
        }
        saveConfiguredServers()
    }

    public func toggleServer(_ serverId: String) {
        if let idx = configuredServers.firstIndex(where: { $0.id == serverId }) {
            configuredServers[idx].isEnabled.toggle()
            saveConfiguredServers()
        }
    }

    public var enabledServers: [MCPServer] {
        configuredServers.filter { $0.isEnabled }
    }

    // MARK: - Persistence

    private func loadConfiguredServers() {
        guard let data = UserDefaults.standard.data(forKey: configuredKey),
              let servers = try? JSONDecoder().decode([MCPServer].self, from: data)
        else { return }
        configuredServers = servers
    }

    private func saveConfiguredServers() {
        if let data = try? JSONEncoder().encode(configuredServers) {
            UserDefaults.standard.set(data, forKey: configuredKey)
        }
    }
}
