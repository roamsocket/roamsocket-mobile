import SwiftUI

/// Identifies which top-level destination the sidebar wants to navigate to.
enum SidebarDestination: Hashable {
    case chats
    case vision
    case study
    case classes
    case scanQuestions
    case projects
    case artifacts
    case code
    case browser
    case models
    case chat(ChatHistoryItem)
    case project(ProjectItem)
}

/// The left-edge navigation drawer.
struct SidebarView: View {
    @ObservedObject var history: ChatHistoryStore
    var onSelect: (SidebarDestination) -> Void
    var onNewChat: () -> Void
    var onShowSettings: () -> Void
    var onRetryDownload: (String) -> Void
    var onCancelDownload: (String) -> Void

    @State private var renameTarget: ChatHistoryItem?
    @State private var addToProjectTarget: ChatHistoryItem?
    @AppStorage("studyMode.v1") private var studyMode: Bool = false

    var body: some View {
        // Single List so the whole column scrolls (header, top nav,
        // recents, downloads, bottom bar all ride together). A long
        // recents list no longer pushes the "New chat" button off the
        // bottom — it just keeps scrolling. The chat row swipeActions
        // and contextMenu are preserved because rows are still inside
        // a List.
        List {
            Section {
                header.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                navListContent
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                recentsContent
            } header: {
                Text("Recents")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(nil)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                downloadBarContent
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                bottomBar
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        // Solid fill so chat carets / selection chrome never show
        // through the list. Keep the horizontal padding the VStack
        // version used so the new "List" version lines up.
        .background {
            Rectangle()
                .fill(Theme.background)
                .ignoresSafeArea(edges: .vertical)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $renameTarget) { item in
            RenameChatSheet(
                initialTitle: item.title,
                onGenerate: {
                    await history.suggestTitle(for: item.id)
                },
                onSave: { title in
                    history.renameChat(item.id, title: title)
                    renameTarget = nil
                },
                onCancel: {
                    renameTarget = nil
                }
            )
        }
        .sheet(item: $addToProjectTarget) { chat in
            AddChatToProjectSheet(history: history, chat: chat)
                .presentationDetents([.medium])
        }
    }

    /// Per-row content for the top nav (Chats / Vision / Code / etc.).
    /// Used inside the outer List — each row is a SidebarRow.
    @ViewBuilder
    private var navListContent: some View {
        if studyMode {
            SidebarRow(systemImage: "book.closed", title: "Classes") {
                onSelect(.classes)
            }
            SidebarRow(systemImage: "camera.viewfinder", title: "Scan questions") {
                onSelect(.scanQuestions)
            }
            SidebarRow(systemImage: "square.stack.3d.up", title: "Decks") {
                onSelect(.study)
            }
            SidebarRow(systemImage: "square.stack.3d.up.badge.plus", title: "Artifacts") {
                onSelect(.artifacts)
            }
        } else {
            SidebarRow(systemImage: "bubble.left.and.bubble.right", title: "Chats") {
                onSelect(.chats)
            }
            SidebarRow(systemImage: "eye", title: "Vision") {
                onSelect(.vision)
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
        SidebarRow(systemImage: "globe", title: "Browser") {
            onSelect(.browser)
        }
    }

    /// Chat rows for the recents section. Kept as `swipeActions` +
    /// `contextMenu` so the long-press / swipe behaviours still work
    /// when the list is part of the parent sidebar List.
    @ViewBuilder
    private var recentsContent: some View {
        ForEach(history.activeRecents) { item in
            RecentRow(item: item) {
                onSelect(.chat(item))
            }
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
                if !item.isIncognito {
                    Button {
                        addToProjectTarget = item
                    } label: {
                        Label("Add to project", systemImage: "tray.full")
                    }
                }
                if item.isIncognito {
                    Button(role: .destructive) {
                        history.forgetChatNow(item.id)
                    } label: {
                        Label("Forget now", systemImage: "theatermasks")
                    }
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

    /// Downloads bar (only rendered when there are active / failed
    /// downloads — `SidebarDownloadBar` self-collapses to `EmptyView`
    /// when its tracks are empty).
    private var downloadBarContent: some View {
        SidebarDownloadBar(
            onOpenModels: { onSelect(.models) },
            onRetry: onRetryDownload,
            onCancel: onCancelDownload
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("RoamSocket")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            // Study mode toggle: swaps the sidebar links for Study destinations.
            Button {
                studyMode.toggle()
            } label: {
                Image(systemName: studyMode ? "graduationcap.fill" : "graduationcap")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(studyMode ? Theme.accent : Theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(Theme.surfaceElevated, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(
                                studyMode ? Theme.accent.opacity(0.6) : Theme.separator.opacity(0.7),
                                lineWidth: 1
                            )
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(studyMode ? "Exit Study mode" : "Enter Study mode")
            .accessibilityAddTraits(studyMode ? [.isSelected] : [])
        }
        .padding(.bottom, 16)
    }

    // MARK: - Downloads (pinned above the footer)

    private var downloadBar: some View {
        SidebarDownloadBar(
            onOpenModels: { onSelect(.models) },
            onRetry: onRetryDownload,
            onCancel: onCancelDownload
        )
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
    }
}

// MARK: - Subviews

/// Compact download progress pinned above the sidebar footer. Tapping the
/// header opens the Manage models screen; Retry / Cancel act on the shown track.
private struct SidebarDownloadBar: View {
    @ObservedObject private var downloads = LocalMetalDownloadManager.shared
    var onOpenModels: () -> Void
    var onRetry: (String) -> Void
    var onCancel: (String) -> Void

    private var tracks: [LocalMetalDownloadManager.Track] {
        Array(downloads.bannerTracks.prefix(2))
    }

    private var hasActive: Bool {
        tracks.contains { $0.phase == .active }
    }

    var body: some View {
        if tracks.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onOpenModels) {
                    HStack(spacing: 8) {
                        Image(systemName: hasActive ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(hasActive ? Theme.accent : Color.orange)
                        Text(hasActive ? "Downloading" : "Downloads")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hasActive ? "Downloads in progress — open Manage models" : "Failed downloads — open Manage models")

                ForEach(tracks) { track in
                    trackRow(track)
                }
                if downloads.bannerTracks.count > tracks.count {
                    Text("+\(downloads.bannerTracks.count - tracks.count) more")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(12)
            .background(
                Theme.surface,
                in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.separator.opacity(0.55), lineWidth: 1)
            )
            .padding(.top, 12)
            .animation(.easeOut(duration: 0.2), value: tracks.map(\.id))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func trackRow(_ track: LocalMetalDownloadManager.Track) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(track.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if track.phase == .active {
                    Text(track.trailingLabel)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                } else if track.phase == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                } else if track.phase == .error {
                    Text("Failed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.9))
                }
            }
            if track.phase == .active {
                ProgressView(value: min(1, max(0, track.fraction)))
                    .tint(Theme.accent)
                    .animation(.linear(duration: 0.2), value: track.fraction)
            }
            if track.phase == .error, let error = track.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if track.phase == .active {
                Button("Cancel") {
                    onCancel(track.hubID)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
            } else if track.phase == .error {
                Button("Retry") {
                    onRetry(track.hubID)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.displayName), \(track.detailLine)")
    }
}

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
            }
            if item.isIncognito {
                Image(systemName: "theatermasks.fill")
                    .font(.system(size: 12))
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
