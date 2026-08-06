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

            // List is required for swipeActions to work.
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
        Button(action: action) {
            HStack(spacing: 8) {
                if item.isToolCall {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(item.title)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
