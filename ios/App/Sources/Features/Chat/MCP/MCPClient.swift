import Foundation
import Combine

/// Model Context Protocol (MCP) client for tool and context integration
@MainActor
final class MCPClient: ObservableObject {
    @Published var servers: [MCPServerInfo] = []
    @Published var tools: [MCPTool] = []
    @Published var resources: [MCPResource] = []
    @Published var prompts: [MCPPrompt] = []
    @Published var isConnected: Bool = false
    @Published var error: String?
    
    private var cancellables = Set<AnyCancellable>()
    
    /// Connect to an MCP server
    func connect(serverURL: URL, apiKey: String? = nil) async {
        do {
            // Simulate connection - in production, this would use URLSession WebSocket
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay
            
            let serverInfo = MCPServerInfo(
                id: UUID().uuidString,
                name: "MCP Server",
                version: "1.0.0",
                capabilities: MCPCapabilities(tools: true, resources: true, prompts: true, logging: true)
            )
            
            servers.append(serverInfo)
            isConnected = true
            error = nil
            
            // Load available tools, resources, and prompts
            await loadTools()
            await loadResources()
            await loadPrompts()
        } catch {
            self.error = error.localizedDescription
            isConnected = false
        }
    }
    
    /// Disconnect from MCP server
    func disconnect() {
        servers.removeAll()
        tools.removeAll()
        resources.removeAll()
        prompts.removeAll()
        isConnected = false
    }
    
    /// Call a tool
    func callTool(toolId: String, parameters: [String: Any]) async throws -> String {
        guard let tool = tools.first(where: { $0.id == toolId }) else {
            throw MCPError.toolNotFound(toolId)
        }
        
        // Simulate tool execution
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s delay
        
        return "Tool '\(tool.name)' executed successfully with parameters: \(parameters)"
    }
    
    /// Get resource content
    func getResource(uri: String) async throws -> String {
        guard resources.contains(where: { $0.uri == uri }) else {
            throw MCPError.resourceNotFound(uri)
        }
        
        // Simulate resource fetch
        try await Task.sleep(nanoseconds: 500_000_000)
        
        return "Resource content for \(uri)"
    }
    
    /// Load available tools from connected servers
    private func loadTools() async {
        // Sample tools - in production, these would come from the MCP server
        tools = [
            MCPTool(id: "search", name: "search", description: "Search the web", connectorId: "web-search"),
            MCPTool(id: "read_file", name: "read_file", description: "Read a file", connectorId: "google-drive"),
            MCPTool(id: "send_email", name: "send_email", description: "Send an email", connectorId: "gmail"),
            MCPTool(id: "create_event", name: "create_event", description: "Create a calendar event", connectorId: "google-calendar"),
            MCPTool(id: "get_balance", name: "get_balance", description: "Get account balance", connectorId: "cashapp")
        ]
    }
    
    /// Load available resources from connected servers
    private func loadResources() async {
        resources = [
            MCPResource(id: "docs", uri: "file:///docs", name: "Documents", description: "Access documents", connectorId: "google-drive"),
            MCPResource(id: "emails", uri: "gmail:///inbox", name: "Email Inbox", description: "Access email inbox", connectorId: "gmail"),
            MCPResource(id: "calendar", uri: "calendar:///events", name: "Calendar Events", description: "Access calendar events", connectorId: "google-calendar")
        ]
    }
    
    /// Load available prompts from connected servers
    private func loadPrompts() async {
        prompts = [
            MCPPrompt(id: "summarize", name: "summarize", description: "Summarize content", arguments: [
                MCPPrompt.Argument(name: "text", description: "Text to summarize", required: true)
            ]),
            MCPPrompt(id: "translate", name: "translate", description: "Translate text", arguments: [
                MCPPrompt.Argument(name: "text", description: "Text to translate", required: true),
                MCPPrompt.Argument(name: "language", description: "Target language", required: true)
            ])
        ]
    }
}

/// MCP Errors
enum MCPError: LocalizedError {
    case toolNotFound(String)
    case resourceNotFound(String)
    case promptNotFound(String)
    case connectionFailed(String)
    case serverError(String)
    
    var errorDescription: String? {
        switch self {
        case .toolNotFound(let id):
            return "Tool not found: \(id)"
        case .resourceNotFound(let uri):
            return "Resource not found: \(uri)"
        case .promptNotFound(let id):
            return "Prompt not found: \(id)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .serverError(let message):
            return "Server error: \(message)"
        }
    }
}
