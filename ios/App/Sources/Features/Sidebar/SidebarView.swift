import SwiftUI

/// Identifies which top-level destination the sidebar wants to navigate to.
enum SidebarDestination: Hashable {
    case chats
    case projects
    case artifacts
    case code
    case chat(ChatHistoryItem)
    case project(ProjectItem)
}

/// The left-edge navigation drawer.
struct SidebarView: View {
    @ObservedObject var history: ChatHistoryStore
    var onSelect: (SidebarDestination) -> Void
    var onNewChat: () -> Void
    var onShowSettings: () -> Void

    @State private var renameTarget: ChatHistoryItem?
    @State private var renameDraft = ""
    @State private var addToProjectTarget: ChatHistoryItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            navList
            recents
                .frame(maxHeight: .infinity, alignment: .top)
            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Background can extend edge-to-edge; content respects the safe area.
        .background(Theme.background.ignoresSafeArea(edges: .vertical))
        .alert("Rename chat", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
            Button("Save") {
                if let target = renameTarget {
                    history.renameChat(target.id, title: renameDraft)
                }
                renameTarget = nil
            }
        } message: {
            Text("Choose a short name for this chat.")
        }
        .sheet(item: $addToProjectTarget) { chat in
            AddChatToProjectSheet(history: history, chat: chat)
                .presentationDetents([.medium])
                .preferredColorScheme(.dark)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("AnyProv Code")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.bottom, 16)
    }

    // MARK: - Top nav

    private var navList: some View {
        VStack(spacing: 2) {
            SidebarRow(systemImage: "bubble.left.and.bubble.right", title: "Chats") {
                onSelect(.chats)
            }
            SidebarRow(systemImage: "tray.full", title: "Projects") {
                onSelect(.projects)
            }
            SidebarRow(systemImage: "square.stack.3d.up", title: "Artifacts") {
                onSelect(.artifacts)
            }
            SidebarRow(systemImage: "chevron.left.forwardslash.chevron.right", title: "Code") {
                onSelect(.code)
            }
        }
    }

    // MARK: - Recents

    private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recents")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 20)
                .padding(.bottom, 8)

            // List is required for swipeActions + contextMenu on rows.
            // Prefer onTapGesture over Button so long-press / swipe aren't stolen.
            List {
                ForEach(history.activeRecents) { item in
                    RecentRow(item: item) {
                        onSelect(.chat(item))
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            history.archiveChat(item.id)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(Theme.accent)
                        Button {
                            beginRename(item)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(Theme.textSecondary)
                    }
                    .contextMenu {
                        Button {
                            addToProjectTarget = item
                        } label: {
                            Label("Add to project", systemImage: "tray.full")
                        }
                        Button {
                            history.setStarred(item.id, starred: !item.isStarred)
                        } label: {
                            Label(
                                item.isStarred ? "Unstar" : "Star",
                                systemImage: item.isStarred ? "star.slash" : "star"
                            )
                        }
                        Button {
                            beginRename(item)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            history.deleteChat(item.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Bottom bar (profile + new chat, pinned to edge)

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button(action: onShowSettings) {
                ZStack {
                    Circle()
                        .fill(Theme.surfaceElevated)
                        .frame(width: 40, height: 40)
                    Text("JS")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")

            Spacer(minLength: 0)

            Button(action: onNewChat) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text("New chat")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Theme.background)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func beginRename(_ item: ChatHistoryItem) {
        renameTarget = item
        renameDraft = item.title
    }
}

// MARK: - Subviews

private struct SidebarRow: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RecentRow: View {
    let item: ChatHistoryItem
    let action: () -> Void

    var body: some View {
        // Use onTapGesture (not Button) so contextMenu / swipeActions work reliably.
        HStack(spacing: 8) {
            if item.isStarred {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
            } else if item.isToolCall {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(item.title)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .onTapGesture(perform: action)
    }
}

// MARK: - Add to project sheet

private struct AddChatToProjectSheet: View {
    @ObservedObject var history: ChatHistoryStore
    let chat: ChatHistoryItem
    @Environment(\.dismiss) private var dismiss
    @State private var createdName = ""
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            Group {
                if history.projects.isEmpty {
                    ContentUnavailableView(
                        "No projects yet",
                        systemImage: "tray",
                        description: Text("Create a project to organize this chat.")
                    )
                } else {
                    List {
                        ForEach(history.projects) { project in
                            Button {
                                history.addChatToProject(chatID: chat.id, projectID: project.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "tray.full")
                                        .foregroundStyle(Theme.textSecondary)
                                    Text(project.name)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Add to project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New project", isPresented: $showCreate) {
                TextField("Name", text: $createdName)
                Button("Cancel", role: .cancel) {
                    createdName = ""
                }
                Button("Create") {
                    let name = createdName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let project = history.createProject(name: name.isEmpty ? "New project" : name)
                    history.addChatToProject(chatID: chat.id, projectID: project.id)
                    createdName = ""
                    dismiss()
                }
            }
        }
    }
}
