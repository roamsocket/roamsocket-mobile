import Foundation

/// Model Context Protocol (MCP) related types

/// MCP Tool definition
struct MCPTool: Identifiable {
    let id: String
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let connectorId: String?
    
    init(id: String, name: String, description: String, inputSchema: [String: Any] = [:], connectorId: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.connectorId = connectorId
    }
}

/// MCP Resource definition
struct MCPResource: Identifiable, Equatable {
    let id: String
    let uri: String
    let name: String
    let description: String
    let mimeType: String?
    let connectorId: String?
    
    init(id: String, uri: String, name: String, description: String, mimeType: String? = nil, connectorId: String? = nil) {
        self.id = id
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.connectorId = connectorId
    }
}

/// MCP Prompt definition
struct MCPPrompt: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let arguments: [Argument]
    let connectorId: String?
    
    struct Argument: Equatable {
        let name: String
        let description: String
        let required: Bool
    }
    
    init(id: String, name: String, description: String, arguments: [Argument] = [], connectorId: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.arguments = arguments
        self.connectorId = connectorId
    }
}

/// MCP Server capabilities
struct MCPCapabilities: Equatable {
    let tools: Bool
    let resources: Bool
    let prompts: Bool
    let logging: Bool
    
    init(tools: Bool = false, resources: Bool = false, prompts: Bool = false, logging: Bool = false) {
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.logging = logging
    }
}

/// MCP Server info
struct MCPServerInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let capabilities: MCPCapabilities
    let connectorId: String?
    
    init(id: String, name: String, version: String, capabilities: MCPCapabilities, connectorId: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.capabilities = capabilities
        self.connectorId = connectorId
    }
}
