import Foundation

/// Lightweight model for a chat shown in the sidebar Recents list.
struct ChatHistoryItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var lastMessageAt: Date
    /// True when the row is a tool call preview rather than a plain text title.
    var isToolCall: Bool = false

    init(id: UUID = UUID(), title: String, lastMessageAt: Date, isToolCall: Bool = false) {
        self.id = id
        self.title = title
        self.lastMessageAt = lastMessageAt
        self.isToolCall = isToolCall
    }
}

/// A project shown in the Projects list (sidebar -> Projects).
struct ProjectItem: Identifiable, Hashable {
    let id: UUID
    var name: String
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, updatedAt: Date) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
    }
}

/// A single chat inside a project (used in the project detail screen).
struct ProjectChatItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var lastMessageAt: Date

    init(id: UUID = UUID(), title: String, lastMessageAt: Date) {
        self.id = id
        self.title = title
        self.lastMessageAt = lastMessageAt
    }
}

/// In-memory store of chat history and projects. Persisted to disk once
/// the history storage layer is wired up.
@MainActor
final class ChatHistoryStore: ObservableObject {
    @Published var recents: [ChatHistoryItem] = []
    @Published var projects: [ProjectItem] = []
    @Published var projectChats: [UUID: [ProjectChatItem]] = [:]

    init() {}

    func chats(for project: ProjectItem) -> [ProjectChatItem] {
        projectChats[project.id] ?? []
    }

    func startNewChat() {
        recents.insert(ChatHistoryItem(title: "New chat", lastMessageAt: Date()), at: 0)
    }

    func createProject() {
        let new = ProjectItem(name: "New project", updatedAt: Date())
        projects.insert(new, at: 0)
        projectChats[new.id] = []
    }
}
