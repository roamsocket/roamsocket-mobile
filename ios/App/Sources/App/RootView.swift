import SwiftUI
import AnyProvCore
#if canImport(UIKit)
import UIKit
#endif

/// Root navigation:
///  * `ChatView` is the default landing screen.
///  * A left-edge sidebar lists top-level destinations (Chats, Vision,
///    Projects, Artifacts, Code) plus a Recents list and a settings entry.
///    A Study toggle in the header swaps those links for Study destinations
///    (Classes, Scan questions, Decks, Artifacts).
///  * Settings is reachable from the toolbar gear and the sidebar.
struct RootView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var history = ChatHistoryStore()

    @State private var sidebarOpen: Bool = false
    @State private var showSettings: Bool = false
    @State private var showIncognitoSheet: Bool = false
    @State private var showVision: Bool = false
    @State private var showLocalMetal: Bool = false
    @State private var showScanQuestions: Bool = false
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
                        case .study:
                            FlashcardDecksListView()
                        case .studyDeck(let deckID):
                            FlashcardDeckDetailView(deckID: deckID)
                        case .classes:
                            ClassesListView()
                        case .classDetail(let classID):
                            ClassDetailView(classID: classID)
                        case .browser:
                            BrowserHomeView(store: state.browserStore, onOpenSidebar: { setSidebarOpen(true) })
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
        // Sandboxes (E2B) is presented here — not inside
        // AppSettingsView — so the sidebar's "Sandboxes" row works
        // even when Settings is closed. The single
        // `state.showSandboxes` flag is flipped by the sidebar,
        // the unpaired Code-home banner, the Settings E2B card,
        // and any future deep links.
        .sheet(isPresented: Binding(
            get: { state.showSandboxes },
            set: { state.showSandboxes = $0 }
        )) {
            SandboxesView()
                .environmentObject(state)
        }
        // E2B key entry sheet. Same pattern as the Sandboxes
        // sheet: lifted to RootView so the same UI opens from
        // any surface (Settings, the unpaired Code home, the
        // Sandboxes empty state).
        .sheet(isPresented: Binding(
            get: { state.showE2BKeySheet },
            set: { state.showE2BKeySheet = $0 }
        )) {
            E2BKeySheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $showIncognitoSheet) {
            IncognitoChatSheet(
                history: history,
                onStartIncognito: { lifetime in
                    history.startIncognitoChat(
                        lifetime: lifetime,
                        selectedModel: state.selectedModel
                    )
                    chatResumeToken = UUID()
                    path = []
                    setSidebarOpen(false)
                },
                onStartFresh: {
                    history.startNewChat(selectedModel: state.selectedModel)
                    chatResumeToken = UUID()
                    path = []
                    setSidebarOpen(false)
                }
            )
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
        .fullScreenCover(isPresented: $showScanQuestions) {
            StudyScanView()
                .environmentObject(state)
        }
        .onAppear {
            // Hand our ChatHistoryStore to AppState so SettingsSync can read
            // it for GitHub push and write back on restore.
            state.setChatHistory(history)
        }
        .onChange(of: path) { oldPath, newPath in
            // Leaving the chat root for any pushed destination — forget an
            // "on exit" incognito chat the user walked away from.
            if oldPath.isEmpty, !newPath.isEmpty {
                history.forgetActiveIfOnExit()
            }
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
                incognitoToolbarButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) {
                menuToolbarButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                incognitoToolbarButton
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

    /// True while the chat shown in the composer is an incognito chat — used
    /// to highlight the toolbar incognito button so the mode is visible.
    private var activeChatIsIncognito: Bool {
        guard let id = history.activeChatID else { return false }
        return history.recents.first(where: { $0.id == id })?.isIncognito == true
    }

    /// Opens a new incognito chat (or the forget settings when already in one).
    private var incognitoToolbarButton: some View {
        Button(action: { showIncognitoSheet = true }) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(activeChatIsIncognito ? Theme.accent : Theme.textPrimary)
                .frame(width: 40, height: 40)
                .background(Theme.surfaceElevated, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Incognito chat")
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
            history.forgetActiveIfOnExit()
            setSidebarOpen(false)
            showVision = true
        case .study:
            history.discardActiveIfBlank()
            history.forgetActiveIfOnExit()
            path = [.study]
            setSidebarOpen(false)
        case .classes:
            history.discardActiveIfBlank()
            history.forgetActiveIfOnExit()
            path = [.classes]
            setSidebarOpen(false)
        case .scanQuestions:
            history.discardActiveIfBlank()
            history.forgetActiveIfOnExit()
            setSidebarOpen(false)
            showScanQuestions = true
        case .projects:
            // Leaving the composer — drop unsent "New chat" rows from Recents.
            history.discardActiveIfBlank()
            history.forgetActiveIfOnExit()
            path = [.projects]
            setSidebarOpen(false)
        case .artifacts:
            history.discardActiveIfBlank()
            history.forgetActiveIfOnExit()
            path = [.artifacts]
            setSidebarOpen(false)
        case .code:
            history.discardActiveIfBlank()
            history.forgetActiveIfOnExit()
            path = [.code]
            setSidebarOpen(false)
        case .browser:
            history.discardActiveIfBlank()
            history.forgetActiveIfOnExit()
            path = [.browser]
            setSidebarOpen(false)
        case .sandboxes:
            // Open the Sandboxes sheet. The E2B flow is phone-only
            // (see Sandboxes/DirectE2BClient.swift) and works
            // without a paired desktop. The actual sheet is owned by
            // AppSettingsView; flipping `state.showSandboxes` here
            // requests presentation from any surface.
            history.discardActiveIfBlank()
            history.forgetActiveIfOnExit()
            state.showSandboxes = true
            setSidebarOpen(false)
        case .models:
            history.discardActiveIfBlank()
            history.forgetActiveIfOnExit()
            setSidebarOpen(false)
            showLocalMetal = true
        case .chat(let item):
            history.openChat(item)
            chatResumeToken = UUID()
            path = []
            setSidebarOpen(false)
        case .project(let project):
            history.discardActiveIfBlank()
            history.forgetActiveIfOnExit()
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
            history.forgetActiveIfOnExit()
            path = [.code]
        case .vision:
            history.discardActiveIfBlank()
            history.forgetActiveIfOnExit()
            // Leave path as-is under the cover; Vision is a full-screen flow.
            showVision = true
        }
    }
}

enum RootRoute: Hashable {
    case projects
    case artifacts
    case code
    case study
    case studyDeck(UUID)
    case classes
    case classDetail(UUID)
    case browser
    case projectDetail(ProjectItem)
    case projectChat(ProjectItem, ProjectChatItem)
}
