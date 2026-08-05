import Foundation

/// Represents a message in the chat conversation
struct ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var content: String
    var timestamp: Date
    var isStreaming: Bool
    var thoughtProcess: String?
    var toolCalls: [ToolCall]?
    var attachments: [Attachment]?
    var connectorContext: [ConnectorContext]?
    
    enum Role: String, Equatable {
        case user
        case assistant
        case system
        case tool
    }
    
    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        thoughtProcess: String? = nil,
        toolCalls: [ToolCall]? = nil,
        attachments: [Attachment]? = nil,
        connectorContext: [ConnectorContext]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.thoughtProcess = thoughtProcess
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.connectorContext = connectorContext
    }
}

/// Represents a tool call made by the assistant
struct ToolCall: Identifiable {
    let id: UUID
    let name: String
    let parameters: [String: Any]
    var result: String?
    var status: Status
    
    enum Status: Equatable {
        case pending
        case running
        case completed
        case failed(String)
    }
    
    init(id: UUID = UUID(), name: String, parameters: [String: Any], result: String? = nil, status: Status = .pending) {
        self.id = id
        self.name = name
        self.parameters = parameters
        self.result = result
        self.status = status
    }
}

/// Represents an attachment (file, image, etc.)
struct Attachment: Identifiable, Equatable {
    let id: UUID
    let name: String
    let type: AttachmentType
    let url: URL?
    let thumbnailData: Data?
    
    enum AttachmentType: Equatable {
        case image
        case document
        case code
        case other(String)
    }
    
    init(id: UUID = UUID(), name: String, type: AttachmentType, url: URL? = nil, thumbnailData: Data? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.url = url
        self.thumbnailData = thumbnailData
    }
}

/// Context from a connector
struct ConnectorContext: Identifiable, Equatable {
    let id: UUID
    let connectorId: String
    let connectorName: String
    let summary: String
    let itemCount: Int
    
    init(id: UUID = UUID(), connectorId: String, connectorName: String, summary: String, itemCount: Int) {
        self.id = id
        self.connectorId = connectorId
        self.connectorName = connectorName
        self.summary = summary
        self.itemCount = itemCount
    }
}
