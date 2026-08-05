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

/// Holds the placeholder chats + projects shown in the sidebar.
/// In a real build this would be backed by RoomAICloud / local persistence.
@MainActor
final class ChatHistoryStore: ObservableObject {
    @Published var recents: [ChatHistoryItem]
    @Published var projects: [ProjectItem]
    @Published var projectChats: [UUID: [ProjectChatItem]]

    init() {
        // Seed with placeholder recents that mirror the screenshot.
        let now = Date()
        self.recents = [
            ChatHistoryItem(title: "Untitled", lastMessageAt: now.addingTimeInterval(-60 * 6)),
            ChatHistoryItem(title: "Untitled", lastMessageAt: now.addingTimeInterval(-60 * 30)),
            ChatHistoryItem(title: "Plenty of Fish profile blurb", lastMessageAt: now.addingTimeInterval(-3600 * 5)),
            ChatHistoryItem(title: "Untitled", lastMessageAt: now.addingTimeInterval(-3600 * 8)),
            ChatHistoryItem(title: "Checking today's inbox", lastMessageAt: now.addingTimeInterval(-3600 * 26)),
            ChatHistoryItem(title: "Cloudflare agent setup prompt", lastMessageAt: now.addingTimeInterval(-3600 * 38)),
            ChatHistoryItem(title: "Limitations of AI self-assessment", lastMessageAt: now.addingTimeInterval(-3600 * 50)),
            ChatHistoryItem(title: "Fetch https://developers.clo…", lastMessageAt: now.addingTimeInterval(-86400 * 2), isToolCall: true),
            ChatHistoryItem(title: "Stripe discovery and…", lastMessageAt: now.addingTimeInterval(-86400 * 3)),
            ChatHistoryItem(title: "Untitled", lastMessageAt: now.addingTimeInterval(-86400 * 4)),
        ]

        // Seed projects that mirror the second screenshot.
        let seededProjects = [
            ProjectItem(name: "Marketing Class", updatedAt: now.addingTimeInterval(-86400 * 4)),
            ProjectItem(name: "Kind365", updatedAt: now.addingTimeInterval(-86400 * 4)),
            ProjectItem(name: "Society and Technology Project", updatedAt: now.addingTimeInterval(-86400 * 30 * 3)),
            ProjectItem(name: "UUCG", updatedAt: now.addingTimeInterval(-86400 * 30 * 3)),
            ProjectItem(name: "How to use Claude", updatedAt: now.addingTimeInterval(-86400 * 30)),
        ]
        self.projects = seededProjects

        let kind365Chats: [ProjectChatItem] = [
            ProjectChatItem(title: "Getting beta users for your site", lastMessageAt: now.addingTimeInterval(-86400 * 5)),
            ProjectChatItem(title: "Making kindness a daily habit at work", lastMessageAt: now.addingTimeInterval(-86400 * 5)),
            ProjectChatItem(title: "Email outreach needed", lastMessageAt: now.addingTimeInterval(-86400 * 5)),
            ProjectChatItem(title: "Kind365 beta tester recruitment post", lastMessageAt: now.addingTimeInterval(-86400 * 6)),
            ProjectChatItem(title: "Daily kindness app for your newsletter", lastMessageAt: now.addingTimeInterval(-86400 * 14)),
            ProjectChatItem(title: "Follow-up outreach priorities", lastMessageAt: now.addingTimeInterval(-86400 * 14)),
            ProjectChatItem(title: "Facebook cover image for kind365", lastMessageAt: now.addingTimeInterval(-86400 * 14)),
            ProjectChatItem(title: "Importing Gmail contacts to HubSpot", lastMessageAt: now.addingTimeInterval(-86400 * 14)),
            ProjectChatItem(title: "Promoting kind365 app launch to Color…", lastMessageAt: now.addingTimeInterval(-86400 * 14)),
            ProjectChatItem(title: "Kind365 wallpaper with QR code for S2…", lastMessageAt: now.addingTimeInterval(-86400 * 21)),
            ProjectChatItem(title: "Building a Claude Corps resu…", lastMessageAt: now.addingTimeInterval(-86400 * 21)),
        ]
        // Keyed by the Kind365 project id (index 1).
        self.projectChats = [seededProjects[1].id: kind365Chats]
    }

    func chats(for project: ProjectItem) -> [ProjectChatItem] {
        projectChats[project.id] ?? []
    }

    func startNewChat() {
        recents.insert(ChatHistoryItem(title: "Untitled", lastMessageAt: Date()), at: 0)
    }

    func createProject() {
        let new = ProjectItem(name: "New project", updatedAt: Date())
        projects.insert(new, at: 0)
        projectChats[new.id] = []
    }
}
