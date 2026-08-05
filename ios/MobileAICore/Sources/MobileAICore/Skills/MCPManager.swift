import Foundation

/// Manages MCP server configurations.
public final class MCPManager: ObservableObject, @unchecked Sendable {
    @Published public private(set) var configuredServers: [MCPServer] = []
    @Published public private(set) var marketplaceItems: [MCPMarketplaceItem] = []
    
    private let storageKey = "configuredMCPServers.v1"
    
    public init() {
        loadConfiguredServers()
        loadDefaultMarketplace()
    }
    
    /// Add a new MCP server configuration.
    public func addServer(_ server: MCPServer) {
        guard !configuredServers.contains(where: { $0.id == server.id }) else { return }
        configuredServers.append(server)
        saveConfiguredServers()
    }
    
    /// Remove an MCP server configuration.
    public func removeServer(_ serverId: String) {
        configuredServers.removeAll { $0.id == serverId }
        saveConfiguredServers()
    }
    
    /// Toggle an MCP server's enabled state.
    public func toggleServer(_ serverId: String) {
        if let idx = configuredServers.firstIndex(where: { $0.id == serverId }) {
            configuredServers[idx].isEnabled.toggle()
            saveConfiguredServers()
        }
    }
    
    /// Install an MCP server from the marketplace.
    public func installFromMarketplace(_ item: MCPMarketplaceItem) {
        let server = MCPServer(
            id: item.id,
            name: item.name,
            description: item.description,
            command: item.command,
            args: item.args,
            isEnabled: true
        )
        addServer(server)
    }
    
    /// Get all enabled MCP servers.
    public var enabledServers: [MCPServer] {
        configuredServers.filter { $0.isEnabled }
    }
    
    // MARK: - Private
    
    private func loadConfiguredServers() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let servers = try? JSONDecoder().decode([MCPServer].self, from: data)
        else { return }
        configuredServers = servers
    }
    
    private func saveConfiguredServers() {
        if let data = try? JSONEncoder().encode(configuredServers) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func loadDefaultMarketplace() {
        marketplaceItems = [
            MCPMarketplaceItem(
                id: "filesystem",
                name: "Filesystem",
                description: "Read, write, and manage files and directories",
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem"],
                category: "File System",
                installInstructions: "Requires Node.js 18+"
            ),
            MCPMarketplaceItem(
                id: "github",
                name: "GitHub",
                description: "Interact with GitHub repositories, issues, and PRs",
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-github"],
                category: "Development",
                installInstructions: "Requires GitHub token in environment"
            ),
            MCPMarketplaceItem(
                id: "postgres",
                name: "PostgreSQL",
                description: "Query and manage PostgreSQL databases",
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-postgres"],
                category: "Database",
                installInstructions: "Requires PostgreSQL connection string"
            ),
            MCPMarketplaceItem(
                id: "sqlite",
                name: "SQLite",
                description: "Query and manage SQLite databases",
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-sqlite"],
                category: "Database",
                installInstructions: "Requires database file path"
            ),
            MCPMarketplaceItem(
                id: "puppeteer",
                name: "Puppeteer",
                description: "Browser automation and web scraping",
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-puppeteer"],
                category: "Web",
                installInstructions: "Requires Node.js 18+"
            ),
            MCPMarketplaceItem(
                id: "brave-search",
                name: "Brave Search",
                description: "Web search using Brave Search API",
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-brave-search"],
                category: "Search",
                installInstructions: "Requires Brave API key"
            ),
            MCPMarketplaceItem(
                id: "memory",
                name: "Memory",
                description: "Persistent memory across conversations",
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-memory"],
                category: "Utility",
                installInstructions: "No additional setup required"
            ),
            MCPMarketplaceItem(
                id: "git",
                name: "Git",
                description: "Git operations and repository management",
                command: "npx",
                args: ["-y", "@modelcontextprotocol/server-git"],
                category: "Development",
                installInstructions: "Requires git installed"
            )
        ]
    }
}
