import Foundation
import AnyProvCore

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
    /// Pinned / starred chats float to the top of Recents.
    var isStarred: Bool
    /// Model last used for this chat (restored when the chat is reopened).
    var selectedModel: AIModel?
    /// User renamed the chat (or accepted a generated name via rename UI).
    /// Auto-title must not overwrite when true.
    var titleIsUserEdited: Bool
    /// On-device / heuristic auto-title already applied for this chat.
    var didAutoTitle: Bool
    /// User-message count when auto-title last ran (for every-N refresh).
    var autoTitleAtUserCount: Int

    init(
        id: UUID = UUID(),
        title: String,
        lastMessageAt: Date,
        isToolCall: Bool = false,
        messages: [PersistedChatMessage] = [],
        isArchived: Bool = false,
        isStarred: Bool = false,
        selectedModel: AIModel? = nil,
        titleIsUserEdited: Bool = false,
        didAutoTitle: Bool = false,
        autoTitleAtUserCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.lastMessageAt = lastMessageAt
        self.isToolCall = isToolCall
        self.messages = messages
        self.isArchived = isArchived
        self.isStarred = isStarred
        self.selectedModel = selectedModel
        self.titleIsUserEdited = titleIsUserEdited
        self.didAutoTitle = didAutoTitle
        self.autoTitleAtUserCount = autoTitleAtUserCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        lastMessageAt = try c.decode(Date.self, forKey: .lastMessageAt)
        isToolCall = try c.decodeIfPresent(Bool.self, forKey: .isToolCall) ?? false
        messages = try c.decodeIfPresent([PersistedChatMessage].self, forKey: .messages) ?? []
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isStarred = try c.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        selectedModel = try c.decodeIfPresent(AIModel.self, forKey: .selectedModel)
        titleIsUserEdited = try c.decodeIfPresent(Bool.self, forKey: .titleIsUserEdited) ?? false
        // Legacy rows with a real title (not "New chat") already have a name —
        // don't re-run auto-title and clobber them.
        let decodedDidAuto = try c.decodeIfPresent(Bool.self, forKey: .didAutoTitle)
        if let decodedDidAuto {
            didAutoTitle = decodedDidAuto
        } else {
            didAutoTitle = titleIsUserEdited
                || (title != ChatTitleGenerator.defaultTitle && !messages.isEmpty)
        }
        if let count = try c.decodeIfPresent(Int.self, forKey: .autoTitleAtUserCount) {
            autoTitleAtUserCount = count
        } else if didAutoTitle {
            // Legacy: treat current transcript length as already titled so we
            // don't immediately re-name; next refresh waits for +3 user msgs.
            autoTitleAtUserCount = messages.filter { $0.role == "user" }.count
        } else {
            autoTitleAtUserCount = 0
        }
    }
}

/// Codable snapshot of a chat bubble for disk persistence.
struct PersistedChatMessage: Identifiable, Hashable, Codable {
    let id: UUID
    var role: String
    var content: String
    var timestamp: Date
    var thoughtProcess: String?
    /// Collapsed thinking-row label (on-device summary).
    var thoughtSummary: String?
    /// Grey tool-status lines (web search, research, …) restored on reopen.
    var toolSteps: [PersistedToolStep]?

    init(
        id: UUID = UUID(),
        role: String,
        content: String,
        timestamp: Date = Date(),
        thoughtProcess: String? = nil,
        thoughtSummary: String? = nil,
        toolSteps: [PersistedToolStep]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.thoughtProcess = thoughtProcess
        self.thoughtSummary = thoughtSummary
        self.toolSteps = toolSteps
    }
}

/// Lightweight tool step for history (no live running state).
struct PersistedToolStep: Hashable, Codable {
    var id: UUID
    var name: String
    var summary: String
    var detail: String?

    init(id: UUID = UUID(), name: String, summary: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.detail = detail
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
    /// Model last used for this chat (restored when the chat is reopened).
    var selectedModel: AIModel?
    /// User renamed the chat (or accepted a generated name via rename UI).
    var titleIsUserEdited: Bool
    /// On-device / heuristic auto-title already applied for this chat.
    var didAutoTitle: Bool
    /// User-message count when auto-title last ran (for every-N refresh).
    var autoTitleAtUserCount: Int

    init(
        id: UUID = UUID(),
        title: String,
        lastMessageAt: Date,
        messages: [PersistedChatMessage] = [],
        isArchived: Bool = false,
        selectedModel: AIModel? = nil,
        titleIsUserEdited: Bool = false,
        didAutoTitle: Bool = false,
        autoTitleAtUserCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.lastMessageAt = lastMessageAt
        self.messages = messages
        self.isArchived = isArchived
        self.selectedModel = selectedModel
        self.titleIsUserEdited = titleIsUserEdited
        self.didAutoTitle = didAutoTitle
        self.autoTitleAtUserCount = autoTitleAtUserCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        lastMessageAt = try c.decode(Date.self, forKey: .lastMessageAt)
        messages = try c.decodeIfPresent([PersistedChatMessage].self, forKey: .messages) ?? []
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        selectedModel = try c.decodeIfPresent(AIModel.self, forKey: .selectedModel)
        titleIsUserEdited = try c.decodeIfPresent(Bool.self, forKey: .titleIsUserEdited) ?? false
        let decodedDidAuto = try c.decodeIfPresent(Bool.self, forKey: .didAutoTitle)
        if let decodedDidAuto {
            didAutoTitle = decodedDidAuto
        } else {
            didAutoTitle = titleIsUserEdited
                || (title != ChatTitleGenerator.defaultTitle && !messages.isEmpty)
        }
        if let count = try c.decodeIfPresent(Int.self, forKey: .autoTitleAtUserCount) {
            autoTitleAtUserCount = count
        } else if didAutoTitle {
            autoTitleAtUserCount = messages.filter { $0.role == "user" }.count
        } else {
            autoTitleAtUserCount = 0
        }
    }
}

/// Persisted chat history + projects for the sidebar Recents list.
@MainActor
final class ChatHistoryStore: ObservableObject {
    /// Re-run on-device title generation every N user messages (3, 6, 9, …).
    static let autoTitleUserMessageInterval = 3

    @Published var recents: [ChatHistoryItem] = []
    @Published var projects: [ProjectItem] = []
    @Published var projectChats: [UUID: [ProjectChatItem]] = [:]

    /// Project currently in focus (e.g. when the user is inside a project chat).
    @Published var activeProject: ProjectItem?

    /// Chat currently open in the main composer (nil = blank new chat).
    @Published var activeChatID: UUID?

    private let storeKey = "chatHistory.v2"
    /// In-flight on-device title jobs (keyed by chat id).
    private var titleTasks: [UUID: Task<Void, Never>] = [:]
    /// Coalesces disk writes so opening a large chat doesn't block the UI
    /// on a full JSON encode of every transcript.
    private var pendingSaveTask: Task<Void, Never>?

    init() {
        load()
    }

    func chats(for project: ProjectItem) -> [ProjectChatItem] {
        // Hide unsent drafts from the project chat list, same as global Recents.
        (projectChats[project.id] ?? []).filter { !$0.isArchived && !$0.messages.isEmpty }
    }

    /// Active (non-archived) global recents for the sidebar.
    /// Starred chats stay pinned above the rest; both groups stay
    /// newest-first. Blank drafts (no messages yet) stay out of the list.
    var activeRecents: [ChatHistoryItem] {
        let active = recents.filter { !$0.isArchived && !Self.isBlankDraft($0) }
        return active.sorted { a, b in
            if a.isStarred != b.isStarred { return a.isStarred && !b.isStarred }
            return a.lastMessageAt > b.lastMessageAt
        }
    }

    /// True when a chat has never received a real message (sidebar draft).
    static func isBlankDraft(_ item: ChatHistoryItem) -> Bool {
        item.messages.isEmpty
    }

    /// Drop blank "New chat" rows so they don't clutter Recents after the user leaves.
    /// - Parameter keeping: optional id to preserve (e.g. the chat being opened).
    /// - Parameter persist: when false, only mutates memory (caller schedules save).
    func discardBlankDrafts(keeping keepID: UUID? = nil, persist: Bool = true) {
        let before = recents.count
        recents.removeAll { item in
            guard Self.isBlankDraft(item) else { return false }
            if let keepID, item.id == keepID { return false }
            return true
        }
        if let id = activeChatID,
           !recents.contains(where: { $0.id == id }) {
            activeChatID = nil
        }
        if recents.count != before, persist { scheduleSave() }
    }

    /// If the currently active chat never got a message, remove it from storage.
    func discardActiveIfBlank() {
        guard let id = activeChatID,
              let item = recents.first(where: { $0.id == id }),
              Self.isBlankDraft(item)
        else { return }
        recents.removeAll { $0.id == id }
        activeChatID = nil
        save()
    }

    /// Start a blank global chat and make it active.
    /// The row stays hidden from Recents until the first message is saved.
    @discardableResult
    func startNewChat(selectedModel: AIModel? = nil) -> ChatHistoryItem {
        // Leaving an unsent draft — drop it so Recents stays clean.
        discardBlankDrafts()
        let item = ChatHistoryItem(
            title: ChatTitleGenerator.defaultTitle,
            lastMessageAt: Date(),
            selectedModel: selectedModel
        )
        recents.insert(item, at: 0)
        activeChatID = item.id
        activeProject = nil
        save()
        return item
    }

    /// Ensure there is an active chat row for the current conversation.
    @discardableResult
    func ensureActiveChat(selectedModel: AIModel? = nil) -> UUID {
        if let id = activeChatID, recents.contains(where: { $0.id == id }) {
            return id
        }
        return startNewChat(selectedModel: selectedModel).id
    }

    /// Open an existing recent chat for resume.
    ///
    /// Keeps the UI responsive: in-memory active state updates immediately,
    /// while the (potentially large) JSON snapshot is written shortly after
    /// via `scheduleSave()`. Uses the store's own row when present so a
    /// stale sidebar snapshot cannot clobber messages.
    func openChat(_ item: ChatHistoryItem) {
        // Drop the empty draft we were on, if any, before switching.
        // Defer the draft cleanup save so it can coalesce with this open.
        discardBlankDrafts(keeping: item.id, persist: false)

        if let idx = recents.firstIndex(where: { $0.id == item.id }) {
            // Already stored — move existing row to top (preserve messages).
            if idx != 0 {
                let existing = recents.remove(at: idx)
                recents.insert(existing, at: 0)
            }
        } else {
            recents.insert(item, at: 0)
        }
        activeChatID = item.id
        activeProject = nil
        scheduleSave()
    }

    /// Persist messages for the active global chat and refresh its title/time.
    func saveMessages(_ messages: [ChatMessage], for chatID: UUID? = nil) {
        let id = chatID ?? activeChatID
        guard let id else { return }
        guard let idx = recents.firstIndex(where: { $0.id == id }) else { return }

        let persisted = messages.compactMap { Self.persist($0) }
        recents[idx].messages = persisted
        recents[idx].lastMessageAt = Date()
        // Interim title from the first user message until on-device naming finishes.
        if !recents[idx].titleIsUserEdited,
           !recents[idx].didAutoTitle,
           let title = Self.derivedTitle(from: messages) {
            recents[idx].title = title
        }
        // Keep recents sorted by last activity.
        let item = recents.remove(at: idx)
        recents.insert(item, at: 0)
        save()
        // Refresh on-device title every N user messages (also on leave for first title).
        scheduleAutoTitleIfNeeded(chatID: id, projectID: nil, forceIfNeverTitled: false)
    }

    /// Persist the model selection for a global recent chat.
    func saveSelectedModel(_ model: AIModel, for chatID: UUID? = nil) {
        let id = chatID ?? activeChatID
        guard let id, let idx = recents.firstIndex(where: { $0.id == id }) else { return }
        guard recents[idx].selectedModel?.id != model.id else { return }
        recents[idx].selectedModel = model
        save()
    }

    func messages(for chatID: UUID) -> [ChatMessage] {
        guard let item = recents.first(where: { $0.id == chatID }) else { return [] }
        return item.messages.compactMap { Self.chatMessage(from: $0) }
    }

    /// Saved model for a global recent chat, if any.
    func selectedModel(for chatID: UUID) -> AIModel? {
        recents.first(where: { $0.id == chatID })?.selectedModel
    }

    /// Create a new chat scoped to the given project.
    /// Blank project drafts are removed when the user leaves without sending.
    @discardableResult
    func startNewChat(in project: ProjectItem, selectedModel: AIModel? = nil) -> ProjectChatItem {
        discardBlankProjectDrafts(in: project.id)
        discardActiveIfBlank()
        let chat = ProjectChatItem(
            title: ChatTitleGenerator.defaultTitle,
            lastMessageAt: Date(),
            selectedModel: selectedModel
        )
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

    /// Remove blank (no messages) project chats, optionally keeping one id.
    func discardBlankProjectDrafts(in projectID: UUID, keeping keepID: UUID? = nil) {
        guard var list = projectChats[projectID] else { return }
        let before = list.count
        list.removeAll { chat in
            guard chat.messages.isEmpty else { return false }
            if let keepID, chat.id == keepID { return false }
            return true
        }
        guard list.count != before else { return }
        projectChats[projectID] = list
        if let id = activeChatID, !list.contains(where: { $0.id == id }), activeProject?.id == projectID {
            activeChatID = nil
        }
        save()
    }

    /// Drop the active project chat when it has no messages (e.g. pop back to project).
    func discardActiveProjectChatIfBlank(projectID: UUID) {
        guard let id = activeChatID,
              var list = projectChats[projectID],
              let idx = list.firstIndex(where: { $0.id == id }),
              list[idx].messages.isEmpty
        else { return }
        list.remove(at: idx)
        projectChats[projectID] = list
        activeChatID = nil
        save()
    }

    func saveProjectChatMessages(_ messages: [ChatMessage], projectID: UUID, chatID: UUID) {
        guard var list = projectChats[projectID],
              let idx = list.firstIndex(where: { $0.id == chatID })
        else { return }
        list[idx].messages = messages.compactMap { Self.persist($0) }
        list[idx].lastMessageAt = Date()
        if !list[idx].titleIsUserEdited,
           !list[idx].didAutoTitle,
           let title = Self.derivedTitle(from: messages) {
            list[idx].title = title
        }
        projectChats[projectID] = list
        if let pIdx = projects.firstIndex(where: { $0.id == projectID }) {
            projects[pIdx].updatedAt = Date()
        }
        save()
        scheduleAutoTitleIfNeeded(chatID: chatID, projectID: projectID, forceIfNeverTitled: false)
    }

    /// Persist the model selection for a project-scoped chat.
    func saveProjectChatSelectedModel(_ model: AIModel, projectID: UUID, chatID: UUID) {
        guard var list = projectChats[projectID],
              let idx = list.firstIndex(where: { $0.id == chatID })
        else { return }
        guard list[idx].selectedModel?.id != model.id else { return }
        list[idx].selectedModel = model
        projectChats[projectID] = list
        save()
    }

    func projectChatMessages(projectID: UUID, chatID: UUID) -> [ChatMessage] {
        guard let chat = projectChats[projectID]?.first(where: { $0.id == chatID }) else { return [] }
        return chat.messages.compactMap { Self.chatMessage(from: $0) }
    }

    /// Saved model for a project-scoped chat, if any.
    func projectChatSelectedModel(projectID: UUID, chatID: UUID) -> AIModel? {
        projectChats[projectID]?.first(where: { $0.id == chatID })?.selectedModel
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

    func renameChat(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = recents.firstIndex(where: { $0.id == id })
        else { return }
        recents[idx].title = trimmed
        recents[idx].titleIsUserEdited = true
        recents[idx].didAutoTitle = true
        titleTasks[id]?.cancel()
        titleTasks[id] = nil
        save()
    }

    /// Suggest a title for a global recent from its messages (for the rename UI).
    /// Does not mutate storage — caller applies via `renameChat` on Save.
    func suggestTitle(for chatID: UUID) async -> String? {
        guard let item = recents.first(where: { $0.id == chatID }) else { return nil }
        return await Self.suggestTitle(from: item.messages)
    }

    /// Suggest a title for a project chat from its messages (for the rename UI).
    func suggestTitle(projectID: UUID, chatID: UUID) async -> String? {
        guard let chat = projectChats[projectID]?.first(where: { $0.id == chatID }) else { return nil }
        return await Self.suggestTitle(from: chat.messages)
    }

    func setStarred(_ id: UUID, starred: Bool) {
        guard let idx = recents.firstIndex(where: { $0.id == id }) else { return }
        recents[idx].isStarred = starred
        save()
    }

    /// Copy a global recent into a project (keeps the original in Recents).
    @discardableResult
    func addChatToProject(chatID: UUID, projectID: UUID) -> ProjectChatItem? {
        guard let chat = recents.first(where: { $0.id == chatID }),
              projects.contains(where: { $0.id == projectID })
        else { return nil }
        let projectChat = ProjectChatItem(
            title: chat.title,
            lastMessageAt: chat.lastMessageAt,
            messages: chat.messages,
            isArchived: false,
            selectedModel: chat.selectedModel,
            titleIsUserEdited: chat.titleIsUserEdited,
            didAutoTitle: chat.didAutoTitle,
            autoTitleAtUserCount: chat.autoTitleAtUserCount
        )
        var list = projectChats[projectID] ?? []
        list.insert(projectChat, at: 0)
        projectChats[projectID] = list
        if let pIdx = projects.firstIndex(where: { $0.id == projectID }) {
            projects[pIdx].updatedAt = Date()
        }
        save()
        return projectChat
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

    func renameProjectChat(projectID: UUID, chatID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var list = projectChats[projectID],
              let idx = list.firstIndex(where: { $0.id == chatID })
        else { return }
        list[idx].title = trimmed
        list[idx].titleIsUserEdited = true
        list[idx].didAutoTitle = true
        projectChats[projectID] = list
        titleTasks[chatID]?.cancel()
        titleTasks[chatID] = nil
        save()
    }

    func deleteProjectChat(projectID: UUID, chatID: UUID) {
        guard var list = projectChats[projectID] else { return }
        list.removeAll { $0.id == chatID }
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

    /// Debounce disk writes so rapid open/switch/save paths don't stall the
    /// main thread on multi-MB JSON encoding.
    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            // ~1 frame is enough to let navigation + spinner paint first.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    /// Immediate disk write (used by message saves and other durable mutations).
    private func save() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveNow()
    }

    private func saveNow() {
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
        // Cold-start cleanup: drop leftover blank drafts from previous sessions.
        pruneBlankDraftsSilently()
    }

    /// Remove empty global + project drafts left over from previous sessions.
    private func pruneBlankDraftsSilently() {
        let recentCount = recents.count
        recents.removeAll { Self.isBlankDraft($0) }
        var projectsChanged = false
        for (projectID, list) in projectChats {
            let filtered = list.filter { !$0.messages.isEmpty }
            if filtered.count != list.count {
                projectChats[projectID] = filtered
                projectsChanged = true
            }
        }
        var activeCleared = false
        if let id = activeChatID {
            let inRecents = recents.contains(where: { $0.id == id })
            let inProjects = projectChats.values.contains { $0.contains(where: { $0.id == id }) }
            if !inRecents && !inProjects {
                activeChatID = nil
                activeCleared = true
            }
        }
        if recents.count != recentCount || projectsChanged || activeCleared {
            save()
        }
    }

    // MARK: - Mapping

    private static func persist(_ message: ChatMessage) -> PersistedChatMessage? {
        // Skip pure welcome / empty assistant seeds (and in-flight tool shells).
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        let steps: [PersistedToolStep]? = message.toolCalls.flatMap { calls in
            guard !calls.isEmpty else { return nil }
            return calls.map {
                PersistedToolStep(id: $0.id, name: $0.name, summary: $0.summary, detail: $0.detail)
            }
        }
        return PersistedChatMessage(
            id: message.id,
            role: message.role.rawValue,
            content: message.content,
            timestamp: message.timestamp,
            thoughtProcess: message.thoughtProcess,
            thoughtSummary: message.thoughtSummary,
            toolSteps: steps
        )
    }

    private static func chatMessage(from persisted: PersistedChatMessage) -> ChatMessage? {
        guard let role = ChatMessage.Role(rawValue: persisted.role) else { return nil }
        let tools: [ToolCall]? = persisted.toolSteps.flatMap { steps in
            guard !steps.isEmpty else { return nil }
            return steps.map {
                ToolCall(
                    id: $0.id,
                    name: $0.name,
                    summary: $0.summary,
                    detail: $0.detail,
                    status: .completed
                )
            }
        }
        return ChatMessage(
            id: persisted.id,
            role: role,
            content: persisted.content,
            timestamp: persisted.timestamp,
            thoughtProcess: persisted.thoughtProcess,
            thoughtSummary: persisted.thoughtSummary,
            toolCalls: tools
        )
    }

    private static func derivedTitle(from messages: [ChatMessage]) -> String? {
        let users = messages
            .filter { $0.role == .user }
            .map(\.content)
        return ChatTitleGenerator.heuristicTitle(from: users)
    }

    private static func suggestTitle(from messages: [PersistedChatMessage]) async -> String? {
        let users = messages.filter { $0.role == "user" }.map(\.content)
        let assistants = messages.filter { $0.role == "assistant" }.map(\.content)
        return await ChatTitleGenerator.suggestTitle(
            userMessages: users,
            assistantMessages: assistants
        )
    }

    // MARK: - Auto title (on-device)

    /// Generate a sidebar title when the user leaves a chat.
    ///
    /// Names once even before the every-N mark so short chats aren’t left as
    /// “New chat”. Periodic refreshes also run from `saveMessages` every
    /// `autoTitleUserMessageInterval` user messages. Never overwrites a
    /// manual rename. Call **after** persisting the latest messages.
    func autoGenerateTitleIfNeeded(for chatID: UUID, projectID: UUID? = nil) {
        scheduleAutoTitleIfNeeded(chatID: chatID, projectID: projectID, forceIfNeverTitled: true)
    }

    /// - Parameter forceIfNeverTitled: when true (leave path), title once even
    ///   if the user has sent fewer than `autoTitleUserMessageInterval` messages.
    private func scheduleAutoTitleIfNeeded(
        chatID: UUID,
        projectID: UUID?,
        forceIfNeverTitled: Bool
    ) {
        if let projectID {
            guard let chat = projectChats[projectID]?.first(where: { $0.id == chatID }),
                  Self.shouldAutoTitle(
                    userCount: Self.userMessageCount(in: chat.messages),
                    lastTitledAt: chat.autoTitleAtUserCount,
                    titleIsUserEdited: chat.titleIsUserEdited,
                    forceIfNeverTitled: forceIfNeverTitled
                  )
            else { return }
        } else {
            guard let item = recents.first(where: { $0.id == chatID }),
                  Self.shouldAutoTitle(
                    userCount: Self.userMessageCount(in: item.messages),
                    lastTitledAt: item.autoTitleAtUserCount,
                    titleIsUserEdited: item.titleIsUserEdited,
                    forceIfNeverTitled: forceIfNeverTitled
                  )
            else { return }
        }

        titleTasks[chatID]?.cancel()
        titleTasks[chatID] = Task { @MainActor [weak self] in
            // Coalesce rapid persists (user send + assistant reply) so the
            // title sees the latest turn when possible.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.runAutoTitle(
                chatID: chatID,
                projectID: projectID,
                forceIfNeverTitled: forceIfNeverTitled
            )
        }
    }

    private func runAutoTitle(
        chatID: UUID,
        projectID: UUID?,
        forceIfNeverTitled: Bool
    ) async {
        let messages: [PersistedChatMessage]
        let userCount: Int
        if let projectID {
            guard let chat = projectChats[projectID]?.first(where: { $0.id == chatID }) else { return }
            userCount = Self.userMessageCount(in: chat.messages)
            guard Self.shouldAutoTitle(
                userCount: userCount,
                lastTitledAt: chat.autoTitleAtUserCount,
                titleIsUserEdited: chat.titleIsUserEdited,
                forceIfNeverTitled: forceIfNeverTitled
            ) else { return }
            messages = chat.messages
        } else {
            guard let item = recents.first(where: { $0.id == chatID }) else { return }
            userCount = Self.userMessageCount(in: item.messages)
            guard Self.shouldAutoTitle(
                userCount: userCount,
                lastTitledAt: item.autoTitleAtUserCount,
                titleIsUserEdited: item.titleIsUserEdited,
                forceIfNeverTitled: forceIfNeverTitled
            ) else { return }
            messages = item.messages
        }

        let suggested = await Self.suggestTitle(from: messages)

        if let projectID {
            guard var list = projectChats[projectID],
                  let idx = list.firstIndex(where: { $0.id == chatID }),
                  !list[idx].titleIsUserEdited
            else { return }
            if let suggested, !suggested.isEmpty {
                list[idx].title = suggested
            }
            list[idx].didAutoTitle = true
            list[idx].autoTitleAtUserCount = userCount
            projectChats[projectID] = list
            save()
        } else {
            guard let idx = recents.firstIndex(where: { $0.id == chatID }),
                  !recents[idx].titleIsUserEdited
            else { return }
            if let suggested, !suggested.isEmpty {
                recents[idx].title = suggested
            }
            recents[idx].didAutoTitle = true
            recents[idx].autoTitleAtUserCount = userCount
            save()
        }
        titleTasks[chatID] = nil
    }

    private static func userMessageCount(in messages: [PersistedChatMessage]) -> Int {
        messages.filter { $0.role == "user" }.count
    }

    /// Periodic refresh every `autoTitleUserMessageInterval` user messages, plus
    /// an optional one-shot early title when leaving a never-named chat.
    private static func shouldAutoTitle(
        userCount: Int,
        lastTitledAt: Int,
        titleIsUserEdited: Bool,
        forceIfNeverTitled: Bool
    ) -> Bool {
        guard !titleIsUserEdited, userCount > 0 else { return false }
        if userCount > lastTitledAt,
           userCount % autoTitleUserMessageInterval == 0 {
            return true
        }
        if forceIfNeverTitled, lastTitledAt == 0 {
            return true
        }
        return false
    }
}
