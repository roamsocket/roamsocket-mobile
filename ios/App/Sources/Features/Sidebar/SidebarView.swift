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
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                navList
                Spacer(minLength: 0)
                recents
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 100) // leave room for the floating New chat button

            newChatButton
            profileChip
        }
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("AnyProv Code")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.top, 6)
        .padding(.bottom, 18)
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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(history.recents) { item in
                        RecentRow(item: item) {
                            onSelect(.chat(item))
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Floating buttons

    private var newChatButton: some View {
        HStack {
            Spacer()
            Button(action: onNewChat) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text("New chat")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.bottom, 56)
        }
    }

    private var profileChip: some View {
        VStack {
            Spacer()
            HStack {
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
                Spacer()
            }
            .padding(.leading, 16)
            .padding(.bottom, 18)
        }
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
