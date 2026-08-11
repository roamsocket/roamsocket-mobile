import SwiftUI
import AnyProvCore
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
    @State private var showLocalMetal: Bool = false
    @State private var path: [RootRoute] = []
    /// Bumps when the user picks a recent chat so ChatView reloads messages.
    @State private var chatResumeToken = UUID()
    @State private var showWalkthrough =
        !LightweightTasksSettings.load().walkthroughCompleted
    /// Crash reports recorded by the on-device Metal engine, presented one at a
    /// time on launch (each offers copy-logs / delete-model / dismiss).
    @State private var pendingCrashReports: [LocalMetalCrashRecord] = []
    @State private var shownCrashReport: LocalMetalCrashRecord?

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
                await checkForCrashedModels()
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
                        },
                        onRetryDownload: { modelID in
                            LocalMetalDownloadManager.shared.retry(modelID: modelID, appState: state)
                        },
                        onCancelDownload: { modelID in
                            LocalMetalDownloadManager.shared.cancel(modelID: modelID)
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
        .sheet(isPresented: $showLocalMetal) {
            LocalMetalSettingsView()
        }
        .sheet(
            item: $shownCrashReport,
            onDismiss: { resolveCurrentCrashReport() }
        ) { record in
            ModelCrashReportView(record: record)
                .environmentObject(state)
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
        .onOpenURL { url in
            if let link = AppDeepLink.parse(url) {
                applyDeepLink(link)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DeepLinkBridge.didRequestNotification)) { note in
            if let raw = note.userInfo?["destination"] as? String,
               let link = AppDeepLink(rawValue: raw)
            {
                applyDeepLink(link)
            }
        }
        .onAppear {
            // Cold-start from Control Center / Action Button / Shortcuts.
            if let link = DeepLinkBridge.consume() {
                applyDeepLink(link)
            }
        }
    }

    // MARK: - Crash reports

    /// On cold launch, surface any "model crashed" reports recorded during a
    /// previous session — one sheet per report.
    @MainActor
    private func checkForCrashedModels() async {
        guard pendingCrashReports.isEmpty, shownCrashReport == nil else { return }
        let pending = await LocalMetalCrashStore.shared.pendingRecords()
        guard !pending.isEmpty else { return }
        pendingCrashReports = pending
        shownCrashReport = pending.first
    }

    /// The dismissed report has been seen / handled: drop it from the store
    /// and present the next pending one (if any) after the dismissal settles.
    private func resolveCurrentCrashReport() {
        guard let record = pendingCrashReports.first else { return }
        Task { @MainActor in
            await LocalMetalCrashStore.shared.remove(id: record.id)
            pendingCrashReports.removeFirst()
            guard let next = pendingCrashReports.first else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard shownCrashReport == nil,
                  pendingCrashReports.first?.id == next.id
            else { return }
            shownCrashReport = next
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
        case .models:
            history.discardActiveIfBlank()
            setSidebarOpen(false)
            showLocalMetal = true
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

    /// Open Chat / Code / Vision from App Intents, Control Center, Lock Screen,
    /// Action Button, or a `roamsocket://` URL.
    private func applyDeepLink(_ link: AppDeepLink) {
        // Consume any queued bridge payload so onAppear does not double-apply.
        _ = DeepLinkBridge.consume()
        showSettings = false
        setSidebarOpen(false)

        switch link {
        case .chat:
            showVision = false
            history.startNewChat(selectedModel: state.selectedModel)
            chatResumeToken = UUID()
            path = []
        case .code:
            showVision = false
            history.discardActiveIfBlank()
            path = [.code]
        case .vision:
            history.discardActiveIfBlank()
            // Leave path as-is under the cover; Vision is a full-screen flow.
            showVision = true
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
