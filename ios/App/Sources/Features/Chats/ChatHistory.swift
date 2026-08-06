import Foundation

/// Lightweight model for a chat shown in the sidebar Recents list.
struct ChatHistoryItem: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var lastMessageAt: Date
    /// True when the row is a tool call preview rather than a plain text title.
    var isToolCall: Bool
    /// Full message list for resume (text turns only; tool metadata omitted).
    var messages: [PersistedChatMessage]
    /// Hidden from Recents when true (swipe-to-archive).
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        title: String,
        lastMessageAt: Date,
        isToolCall: Bool = false,
        messages: [PersistedChatMessage] = [],
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.lastMessageAt = lastMessageAt
        self.isToolCall = isToolCall
        self.messages = messages
        self.isArchived = isArchived
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        lastMessageAt = try c.decode(Date.self, forKey: .lastMessageAt)
        isToolCall = try c.decodeIfPresent(Bool.self, forKey: .isToolCall) ?? false
        messages = try c.decodeIfPresent([PersistedChatMessage].self, forKey: .messages) ?? []
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

/// Codable snapshot of a chat bubble for disk persistence.
struct PersistedChatMessage: Identifiable, Hashable, Codable {
    let id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var thoughtProcess: String?

    init(
        id: UUID = UUID(),
        role: String,
        content: String,
        timestamp: Date = Date(),
        thoughtProcess: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.thoughtProcess = thoughtProcess
    }
}

/// A project shown in the Projects list (sidebar -> Projects).
struct ProjectItem: Identifiable, Hashable, Codable {
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
struct ProjectChatItem: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var lastMessageAt: Date
    var messages: [PersistedChatMessage]
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        title: String,
        lastMessageAt: Date,
        messages: [PersistedChatMessage] = [],
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.lastMessageAt = lastMessageAt
        self.messages = messages
        self.isArchived = isArchived
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        lastMessageAt = try c.decode(Date.self, forKey: .lastMessageAt)
        messages = try c.decodeIfPresent([PersistedChatMessage].self, forKey: .messages) ?? []
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

/// Persisted chat history + projects for the sidebar Recents list.
@MainActor
final class ChatHistoryStore: ObservableObject {
    @Published var recents: [ChatHistoryItem] = []
    @Published var projects: [ProjectItem] = []
    @Published var projectChats: [UUID: [ProjectChatItem]] = [:]

    /// Project currently in focus (e.g. when the user is inside a project chat).
    @Published var activeProject: ProjectItem?

    /// Chat currently open in the main composer (nil = blank new chat).
    @Published var activeChatID: UUID?

    private let storeKey = "chatHistory.v2"

    init() {
        load()
    }

    func chats(for project: ProjectItem) -> [ProjectChatItem] {
        (projectChats[project.id] ?? []).filter { !$0.isArchived }
    }

    /// Active (non-archived) global recents for the sidebar.
    var activeRecents: [ChatHistoryItem] {
        recents.filter { !$0.isArchived }
    }

    /// Start a blank global chat and make it active.
    @discardableResult
    func startNewChat() -> ChatHistoryItem {
        let item = ChatHistoryItem(title: "New chat", lastMessageAt: Date())
        recents.insert(item, at: 0)
        activeChatID = item.id
        activeProject = nil
        save()
        return item
    }

    /// Ensure there is an active chat row for the current conversation.
    @discardableResult
    func ensureActiveChat() -> UUID {
        if let id = activeChatID, recents.contains(where: { $0.id == id }) {
            return id
        }
        return startNewChat().id
    }

    /// Open an existing recent chat for resume.
    func openChat(_ item: ChatHistoryItem) {
        // Move to top of recents.
        recents.removeAll { $0.id == item.id }
        recents.insert(item, at: 0)
        activeChatID = item.id
        activeProject = nil
        save()
    }

    /// Persist messages for the active global chat and refresh its title/time.
    func saveMessages(_ messages: [ChatMessage], for chatID: UUID? = nil) {
        let id = chatID ?? activeChatID
        guard let id else { return }
        guard let idx = recents.firstIndex(where: { $0.id == id }) else { return }

        let persisted = messages.compactMap { Self.persist($0) }
        recents[idx].messages = persisted
        recents[idx].lastMessageAt = Date()
        if let title = Self.derivedTitle(from: messages) {
            recents[idx].title = title
        }
        // Keep recents sorted by last activity.
        let item = recents.remove(at: idx)
        recents.insert(item, at: 0)
        save()
    }

    func messages(for chatID: UUID) -> [ChatMessage] {
        guard let item = recents.first(where: { $0.id == chatID }) else { return [] }
        return item.messages.compactMap { Self.chatMessage(from: $0) }
    }

    /// Create a new chat scoped to the given project.
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
        activeChatID = chat.id
        save()
        return chat
    }

    func saveProjectChatMessages(_ messages: [ChatMessage], projectID: UUID, chatID: UUID) {
        guard var list = projectChats[projectID],
              let idx = list.firstIndex(where: { $0.id == chatID })
        else { return }
        list[idx].messages = messages.compactMap { Self.persist($0) }
        list[idx].lastMessageAt = Date()
        if let title = Self.derivedTitle(from: messages) {
            list[idx].title = title
        }
        projectChats[projectID] = list
        if let pIdx = projects.firstIndex(where: { $0.id == projectID }) {
            projects[pIdx].updatedAt = Date()
        }
        save()
    }

    func projectChatMessages(projectID: UUID, chatID: UUID) -> [ChatMessage] {
        guard let chat = projectChats[projectID]?.first(where: { $0.id == chatID }) else { return [] }
        return chat.messages.compactMap { Self.chatMessage(from: $0) }
    }

    @discardableResult
    func createProject(name: String = "New project", description: String = "") -> ProjectItem {
        let new = ProjectItem(name: name, updatedAt: Date())
        projects.insert(new, at: 0)
        projectChats[new.id] = []
        save()
        return new
    }

    func project(for chat: ProjectChatItem) -> ProjectItem? {
        for project in projects {
            if let list = projectChats[project.id], list.contains(where: { $0.id == chat.id }) {
                return project
            }
        }
        return nil
    }

    func deleteChat(_ id: UUID) {
        recents.removeAll { $0.id == id }
        if activeChatID == id { activeChatID = nil }
        save()
    }

    /// Swipe-to-archive for a global recent chat.
    func archiveChat(_ id: UUID) {
        guard let idx = recents.firstIndex(where: { $0.id == id }) else { return }
        recents[idx].isArchived = true
        if activeChatID == id { activeChatID = nil }
        save()
    }

    func unarchiveChat(_ id: UUID) {
        guard let idx = recents.firstIndex(where: { $0.id == id }) else { return }
        recents[idx].isArchived = false
        save()
    }

    /// Swipe-to-archive for a project chat.
    func archiveProjectChat(projectID: UUID, chatID: UUID) {
        guard var list = projectChats[projectID],
              let idx = list.firstIndex(where: { $0.id == chatID })
        else { return }
        list[idx].isArchived = true
        projectChats[projectID] = list
        if activeChatID == chatID { activeChatID = nil }
        save()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var recents: [ChatHistoryItem]
        var projects: [ProjectItem]
        var projectChats: [String: [ProjectChatItem]]
        var activeChatID: UUID?
    }

    private func save() {
        let chats: [String: [ProjectChatItem]] = Dictionary(
            uniqueKeysWithValues: projectChats.map { ($0.key.uuidString, $0.value) }
        )
        let snap = Snapshot(
            recents: recents,
            projects: projects,
            projectChats: chats,
            activeChatID: activeChatID
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        recents = snap.recents
        projects = snap.projects
        projectChats = Dictionary(
            uniqueKeysWithValues: snap.projectChats.compactMap { key, value in
                guard let id = UUID(uuidString: key) else { return nil }
                return (id, value)
            }
        )
        activeChatID = snap.activeChatID
    }

    // MARK: - Mapping

    private static func persist(_ message: ChatMessage) -> PersistedChatMessage? {
        // Skip pure welcome / empty assistant seeds.
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return PersistedChatMessage(
            id: message.id,
            role: message.role.rawValue,
            content: message.content,
            timestamp: message.timestamp,
            thoughtProcess: message.thoughtProcess
        )
    }

    private static func chatMessage(from persisted: PersistedChatMessage) -> ChatMessage? {
        guard let role = ChatMessage.Role(rawValue: persisted.role) else { return nil }
        return ChatMessage(
            id: persisted.id,
            role: role,
            content: persisted.content,
            timestamp: persisted.timestamp,
            thoughtProcess: persisted.thoughtProcess
        )
    }

    private static func derivedTitle(from messages: [ChatMessage]) -> String? {
        guard let firstUser = messages.first(where: { $0.role == .user }) else { return nil }
        let trimmed = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 48 { return trimmed }
        return String(trimmed.prefix(45)) + "…"
    }
}
