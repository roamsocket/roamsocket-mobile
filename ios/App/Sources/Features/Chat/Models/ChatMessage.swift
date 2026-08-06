import Foundation

/// Represents a message in the chat conversation
struct ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var content: String
    var timestamp: Date
    var isStreaming: Bool
    var thoughtProcess: String?
    /// One-line label for the collapsed thinking row (on-device summary).
    var thoughtSummary: String?
    /// Tool steps (web search, research, …) shown as grey status text.
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
        thoughtSummary: String? = nil,
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
        self.thoughtSummary = thoughtSummary
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.connectorContext = connectorContext
    }
}

/// A tool step the assistant ran (or is running) for this turn.
/// Shown in the UI as grey status text above the reply body.
struct ToolCall: Identifiable, Equatable {
    let id: UUID
    /// Machine name: `web_search`, `wikipedia`, `research`, etc.
    let name: String
    /// Human-readable grey line, e.g. `Searched the web for "…"`.
    var summary: String
    /// Optional secondary detail (source count, short extract).
    var detail: String?
    var result: String?
    var status: Status

    enum Status: Equatable {
        case pending
        case running
        case completed
        case failed(String)
    }

    init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        detail: String? = nil,
        result: String? = nil,
        status: Status = .pending
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.detail = detail
        self.result = result
        self.status = status
    }

    init(from step: WebSearchService.Step) {
        self.id = step.id
        self.name = step.name
        self.summary = step.summary
        self.detail = step.detail
        self.result = step.detail
        switch step.status {
        case .pending: self.status = .pending
        case .running: self.status = .running
        case .completed: self.status = .completed
        case let .failed(msg): self.status = .failed(msg)
        }
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
