import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Root navigation:
///  * `ChatView` is the default landing screen.
///  * A left-edge sidebar lists top-level destinations (Chats, Vision,
///    Projects, Artifacts, Code) plus a Recents list and a settings entry.
///  * Settings is reachable from the toolbar gear and the sidebar.
struct RootView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var history = ChatHistoryStore()

    @State private var sidebarOpen: Bool = false
    @State private var showSettings: Bool = false
    @State private var showVision: Bool = false
    @State private var path: [RootRoute] = []
    /// Bumps when the user picks a recent chat so ChatView reloads messages.
    @State private var chatResumeToken = UUID()
    @State private var showWalkthrough =
        !LightweightTasksSettings.load().walkthroughCompleted

    var body: some View {
        ZStack {
            NavigationStack(path: $path) {
                ChatView(
                    onOpenSidebar: { setSidebarOpen(true) },
                    path: $path,
                    history: history,
                    resumeToken: chatResumeToken
                )
                    .toolbar { toolbar }
                    .navigationDestination(for: RootRoute.self) { route in
                        switch route {
                        case .projects:
                            ProjectsListView(history: history)
                        case .artifacts:
                            ArtifactsListView(
                                history: history,
                                path: $path,
                                onOpenedInChat: { chatResumeToken = UUID() }
                            )
                        case .code:
                            CodeHomeView(onOpenSidebar: { setSidebarOpen(true) })
                        case .projectDetail(let project):
                            ProjectDetailView(project: project, history: history, path: $path)
                        case .projectChat(let project, let chat):
                            ChatView(
                                project: project,
                                chat: chat,
                                path: $path,
                                history: history,
                                resumeToken: chatResumeToken
                            )
                        }
                    }
            }
            // Block interaction with the chat under the drawer (selection /
            // keyboard should already be cleared via `setSidebarOpen`).
            .allowsHitTesting(!sidebarOpen)
            .task {
                if state.allModels.isEmpty { await state.refreshModels() }
            }

            // Full-height edge drawer (not a floating card)
            if sidebarOpen {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { setSidebarOpen(false) }
                    .zIndex(1)

                HStack(spacing: 0) {
                    SidebarView(
                        history: history,
                        onSelect: { destination in
                            handle(destination: destination)
                        },
                        onNewChat: {
                            // startNewChat discards any previous blank draft first.
                            history.startNewChat(selectedModel: state.selectedModel)
                            chatResumeToken = UUID()
                            path = []
                            setSidebarOpen(false)
                        },
                        onShowSettings: {
                            setSidebarOpen(false)
                            showSettings = true
                        }
                    )
                    .frame(width: 300)
                    .frame(maxHeight: .infinity, alignment: .top)
                    // Fully opaque panel under the status bar (content stays safe-area aware).
                    .background {
                        Rectangle()
                            .fill(Theme.background)
                            .ignoresSafeArea()
                    }
                    // Flatten so underlying chat selection chrome can't blend through.
                    .compositingGroup()
                    .transition(.move(edge: .leading))

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .zIndex(2)
            }
        }
        .sheet(isPresented: $showSettings) {
            AppSettingsView()
        }
        .fullScreenCover(isPresented: $showWalkthrough) {
            OnboardingWalkthroughView {
                showWalkthrough = false
            }
            .environmentObject(state)
        }
        .fullScreenCover(isPresented: $showVision) {
            VisionView()
                .environmentObject(state)
        }
        .onChange(of: path) { oldPath, newPath in
            // Returning to the chat root (e.g. system back from Code) — refresh
            // so a discarded blank draft doesn't leave a stale empty shell, and
            // so the composer layout is rebuilt after being covered.
            guard newPath.isEmpty, !oldPath.isEmpty else { return }
            chatResumeToken = UUID()
        }
    }

    // MARK: - Sidebar

    /// Open/close the drawer. Resigns first responder so carets and text
    /// selection handles (UIKit layers above SwiftUI) don't float over the panel.
    private func setSidebarOpen(_ open: Bool) {
        if open {
            resignTextSelection()
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            sidebarOpen = open
        }
    }

    private func resignTextSelection() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // On iOS 26+ the nav bar applies a liquid-glass shared background
        // around toolbar items. We already draw our own circle, so hide the
        // system chrome to avoid a double ring.
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) {
                menuToolbarButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .topBarTrailing) {
                settingsToolbarButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) {
                menuToolbarButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                settingsToolbarButton
            }
        }
    }

    private var menuToolbarButton: some View {
        Button(action: { setSidebarOpen(!sidebarOpen) }) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 40, height: 40)
                .background(Theme.surfaceElevated, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Menu")
    }

    private var settingsToolbarButton: some View {
        Button(action: { showSettings = true }) {
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 40, height: 40)
                .background(Theme.surfaceElevated, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    // MARK: - Routing

    private func handle(destination: SidebarDestination) {
        switch destination {
        case .chats:
            // "Chats" is the home entry point — always land on a fresh chat.
            history.startNewChat(selectedModel: state.selectedModel)
            chatResumeToken = UUID()
            path = []
            setSidebarOpen(false)
        case .vision:
            history.discardActiveIfBlank()
            setSidebarOpen(false)
            showVision = true
        case .projects:
            // Leaving the composer — drop unsent "New chat" rows from Recents.
            history.discardActiveIfBlank()
            path = [.projects]
            setSidebarOpen(false)
        case .artifacts:
            history.discardActiveIfBlank()
            path = [.artifacts]
            setSidebarOpen(false)
        case .code:
            history.discardActiveIfBlank()
            path = [.code]
            setSidebarOpen(false)
        case .chat(let item):
            history.openChat(item)
            chatResumeToken = UUID()
            path = []
            setSidebarOpen(false)
        case .project(let project):
            history.discardActiveIfBlank()
            path = [.projectDetail(project)]
            setSidebarOpen(false)
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
