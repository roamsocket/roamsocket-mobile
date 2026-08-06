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

    /// Project currently in focus (e.g. when the user is inside a project
    /// chat). The chat view reads this to show the project pill in its
    /// header and to associate new messages with the project.
    @Published var activeProject: ProjectItem?

    init() {}

    func chats(for project: ProjectItem) -> [ProjectChatItem] {
        projectChats[project.id] ?? []
    }

    func startNewChat() {
        recents.insert(ChatHistoryItem(title: "New chat", lastMessageAt: Date()), at: 0)
    }

    /// Create a new chat scoped to the given project. Returns the new chat
    /// so callers can navigate straight into it.
    @discardableResult
    func startNewChat(in project: ProjectItem) -> ProjectChatItem {
        let chat = ProjectChatItem(title: "New chat", lastMessageAt: Date())
        var list = projectChats[project.id] ?? []
        list.insert(chat, at: 0)
        projectChats[project.id] = list
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx].updatedAt = Date()
        }
        activeProject = project
        return chat
    }

    /// Create a new project and return it so callers can navigate or
    /// immediately start a chat inside it.
    @discardableResult
    func createProject(name: String = "New project", description: String = "") -> ProjectItem {
        let new = ProjectItem(name: name, updatedAt: Date())
        projects.insert(new, at: 0)
        projectChats[new.id] = []
        return new
    }

    /// Find a project by its chat's ID. Used by the chat view to look up
    /// the project for the "project pill" in the header.
    func project(for chat: ProjectChatItem) -> ProjectItem? {
        for project in projects {
            if let list = projectChats[project.id], list.contains(where: { $0.id == chat.id }) {
                return project
            }
        }
        return nil
    }
}
