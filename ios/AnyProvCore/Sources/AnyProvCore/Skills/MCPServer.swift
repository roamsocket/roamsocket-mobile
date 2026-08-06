import Foundation

/// An MCP (Model Context Protocol) server configuration.
public struct MCPServer: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let command: String
    public let args: [String]
    public let env: [String: String]
    public var isEnabled: Bool
    
    public init(
        id: String,
        name: String,
        description: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        isEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.command = command
        self.args = args
        self.env = env
        self.isEnabled = isEnabled
    }
}

/// A marketplace listing of available MCP servers.
public struct MCPMarketplaceItem: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let command: String
    public let args: [String]
    public let category: String
    public let installInstructions: String
    
    public init(
        id: String,
        name: String,
        description: String,
        command: String,
        args: [String] = [],
        category: String,
        installInstructions: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.command = command
        self.args = args
        self.category = category
        self.installInstructions = installInstructions
    }
}
