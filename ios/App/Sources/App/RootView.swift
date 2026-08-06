import SwiftUI

/// Root navigation:
///  * `ChatView` is the default landing screen (mimicking the Claude iOS app).
///  * A left-edge sidebar lists top-level destinations (Chats, Projects,
///    Artifacts, Code) plus a Recents list and a profile chip.
///  * Settings is reachable from the sidebar profile.
struct RootView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var history = ChatHistoryStore()

    @State private var sidebarOpen: Bool = false
    @State private var showSettings: Bool = false
    @State private var path: [RootRoute] = []

    var body: some View {
        ZStack {
            NavigationStack(path: $path) {
                ChatView(onOpenSidebar: { sidebarOpen = true })
                    .toolbar { toolbar }
                    .navigationDestination(for: RootRoute.self) { route in
                        switch route {
                        case .projects:
                            ProjectsListView(history: history)
                        case .artifacts:
                            ArtifactsListView()
                        case .code:
                            CodeHomeView(onOpenSidebar: { sidebarOpen = true })
                        case .projectDetail(let project):
                            ProjectDetailView(project: project, history: history, path: $path)
                        case .projectChat(let project, let chat):
                            ChatView(project: project, chat: chat, path: $path)
                        }
                    }
            }
            .task {
                if state.allModels.isEmpty { await state.refreshModels() }
            }

            // Sidebar drawer overlay
            if sidebarOpen {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { sidebarOpen = false } }

                HStack(spacing: 0) {
                    SidebarView(
                        history: history,
                        onSelect: { destination in
                            handle(destination: destination)
                        },
                        onNewChat: {
                            history.startNewChat()
                            path = []
                            withAnimation(.easeInOut(duration: 0.25)) { sidebarOpen = false }
                        },
                        onShowSettings: {
                            withAnimation(.easeInOut(duration: 0.25)) { sidebarOpen = false }
                            showSettings = true
                        }
                    )
                    .frame(width: 300)
                    .background(Theme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .padding(.vertical, 12)
                    .padding(.leading, 8)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                    Spacer(minLength: 0)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            ClaudeSettingsView()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: { withAnimation(.easeInOut(duration: 0.25)) { sidebarOpen.toggle() } }) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: { showSettings = true }) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Routing

    private func handle(destination: SidebarDestination) {
        switch destination {
        case .chats:
            path = []
            withAnimation(.easeInOut(duration: 0.25)) { sidebarOpen = false }
        case .projects:
            path = [.projects]
            withAnimation(.easeInOut(duration: 0.25)) { sidebarOpen = false }
        case .artifacts:
            path = [.artifacts]
            withAnimation(.easeInOut(duration: 0.25)) { sidebarOpen = false }
        case .code:
            path = [.code]
            withAnimation(.easeInOut(duration: 0.25)) { sidebarOpen = false }
        case .chat(let item):
            history.recents.removeAll { $0.id == item.id }
            history.recents.insert(item, at: 0)
            path = []
            withAnimation(.easeInOut(duration: 0.25)) { sidebarOpen = false }
        case .project(let project):
            path = [.projectDetail(project)]
            withAnimation(.easeInOut(duration: 0.25)) { sidebarOpen = false }
        }
    }
}

enum RootRoute: Hashable {
    case projects
    case artifacts
    case code
    case projectDetail(ProjectItem)
    case projectChat(ProjectItem, ProjectChatItem)
}
