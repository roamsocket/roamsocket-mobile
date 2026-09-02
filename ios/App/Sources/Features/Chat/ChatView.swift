import SwiftUI
import UIKit
import AnyProvCore

/// Main chat view:
///  * On a fresh / empty chat, shows a centered time-based greeting with a
///    lightbulb icon.
///  * Otherwise renders a vertically scrolling message list.
///  * The bottom composer holds a `+` button, a model pill, and a
///    gradient send button.
struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @EnvironmentObject var state: AppState
    var onOpenSidebar: () -> Void = {}

    /// Optional project context. When set, the chat's title becomes a
    /// tappable pill that lets the user jump back to the project.
    var project: ProjectItem? = nil
    var chat: ProjectChatItem? = nil

    /// Optional binding to the root navigation path. When provided, the
    /// project pill in the header pops back to the project detail by
    /// removing the last route from the path.
    var path: Binding<[RootRoute]>? = nil

    /// Shared sidebar history (persisted). When nil, chat is ephemeral.
    var history: ChatHistoryStore? = nil
    /// Changes when the user picks New chat / a recent row so we reload.
    var resumeToken: UUID = UUID()

    /// Set when the user hits Send and the prerequisites for a coding session
    /// are met (paired server + repo + model with API key). The fullScreenCover
    /// takes over the chat until the session ends.
    @State private var sessionConfig: SessionConfig?

    /// Shown when the user taps the model pill with no usable model
    /// configured. Lands directly on the providers section of the
    /// settings screen.
    @State private var showProviderSettings = false

    /// Set when a coding-session launch is requested from the chat but the
    /// prerequisites (paired server, repo, model with key) aren't met.
    @State private var sessionLaunchError: String?

    /// Full-screen live voice chat (Siri dictation + spoken replies).
    @State private var showVoiceChat = false

    /// Study mode (sidebar graduation-cap toggle). When on, every send
    /// attaches web sources, shown as a locked Sources chip above the composer.
    @AppStorage("studyMode.v1") private var studyMode: Bool = false

    /// Extra bottom lift so the composer sits above the software keyboard.
    /// System keyboard avoidance is unreliable here (full-bleed background +
    /// sibling composer VStack), so we track the keyboard frame ourselves.
    @State private var keyboardLift: CGFloat = 0

    private var keyboardVisible: Bool { keyboardLift > 10 }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            // Content + composer in a VStack. `safeAreaInset` alone was sometimes
            // zero-height after returning from Code / other destinations, which
            // hid the input; keeping the composer as a real sibling fixes that.
            VStack(spacing: 0) {
                Group {
                    if viewModel.isLoadingChat {
                        chatLoadingState
                    } else if isEffectivelyEmpty {
                        emptyHome
                    } else {
                        chatBodyWithOptionalArtifact
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(0)

                composer
                    .layoutPriority(1)
            }
            // Lift the whole column (transcript shrinks; composer rides up).
            .padding(.bottom, keyboardLift)
            .animation(.easeOut(duration: 0.25), value: keyboardLift)
        }
        // Own keyboard avoidance via `keyboardLift`. Without this, SwiftUI also
        // applies the keyboard safe-area inset and the composer ends up roughly
        // one keyboard-height too high (large empty band above the keys).
        .ignoresSafeArea(.keyboard)
        .onAppear {
            bindAndLoad()
        }
        .task {
            // The chat path is reached via RootView's task today,
            // but the Sandboxes sidebar entry used to be a
            // second refresh hook — and other surfaces (Code /
            // E2B / Sandboxes in Settings) already call
            // `refreshModels` on appear. Pin the chat to the same
            // contract so the model pill never opens an empty
            // picker just because the user landed here first.
            if state.allModels.isEmpty {
                await state.refreshModels()
            }
        }
        .onChange(of: resumeToken) {
            // Switching chats / new chat while this screen stays mounted.
            persistAndAutoTitleOnLeave()
            bindAndLoad()
        }
        .onChange(of: navigationPathDepth) { oldCount, newCount in
            // Root ChatView stays alive under NavigationStack when Code /
            // Projects / etc. are pushed — onDisappear does not fire. Title
            // the chat as soon as we navigate away from the empty path.
            guard project == nil, oldCount == 0, newCount > 0 else { return }
            persistAndAutoTitleOnLeave()
        }
        .onDisappear {
            // Project chat pop, or any full teardown of this chat screen.
            persistAndAutoTitleOnLeave()
            discardBlankDraftIfNeeded()
            keyboardLift = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboardLift(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardLift = 0
        }
        // Keep the bar compact — large-title mode reserves a tall blank band
        // under the chrome and makes the empty home look top-padded.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Center title: when in a project, show a tappable pill with
            // the folder icon and project name. Otherwise show the chat title.
            ToolbarItem(placement: .principal) {
                if let project {
                    projectPill(project)
                } else {
                    Text(chatTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
            }
        }
        .sheet(isPresented: $viewModel.showAddToChatSheet) {
            AddToChatSheet(viewModel: viewModel) { task in
                if let config = SessionLauncher.makeConfig(in: state, task: task) {
                    sessionConfig = config
                } else {
                    let missing = SessionLauncher.missingRequirements(in: state)
                    sessionLaunchError = missing.isEmpty
                        ? "Pick a coding model with an API key, then start again."
                        : missing.joined(separator: "\n")
                }
            }
        }
        .alert("Start a coding session", isPresented: sessionLaunchErrorBinding) {
            Button("OK", role: .cancel) { sessionLaunchError = nil }
        } message: {
            Text(sessionLaunchError ?? "")
        }
        .sheet(isPresented: $viewModel.showCamera) {
            CameraCapture(isPresented: $viewModel.showCamera) { data in
                viewModel.attachCameraImage(data)
            }
        }
        .sheet(isPresented: $viewModel.showGallery) {
            // selectionLimit mirrors ChatViewModel.maxAttachedImages so the
            // picker can't return more than the composer would accept.
            GalleryPicker(
                isPresented: $viewModel.showGallery,
                selectionLimit: ChatViewModel.maxAttachedImages
            ) { payloads in
                viewModel.attachGalleryImages(payloads)
            }
        }
        .sheet(isPresented: $viewModel.showConnectorsView) {
            ConnectorsView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showModelPicker, onDismiss: {
            // Capture the picker's selection onto this chat only after an
            // intentional dismiss — not when catalog refresh mutates selection.
            viewModel.persistSelectedModel()
        }) {
            ModelPickerSheet()
        }
        .sheet(isPresented: $showProviderSettings) {
            AppSettingsView(initialFocus: .providers)
        }
        .fullScreenCover(item: $sessionConfig) { config in
            NavigationStack {
                SessionView(config: config)
            }
            .environmentObject(state)
        }
        .fullScreenCover(isPresented: $showVoiceChat) {
            VoiceChatView(
                chatViewModel: viewModel,
                onOpenSidebar: {
                    showVoiceChat = false
                    onOpenSidebar()
                }
            )
            .environmentObject(state)
        }
    }

    // MARK: - Keyboard

    /// Lift amount for content that already sits above the home indicator.
    /// Full keyboard height minus the bottom safe area (already accounted for).
    private func updateKeyboardLift(from note: Notification) {
        guard
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }

        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)

        let overlap: CGFloat
        let bottomSafe: CGFloat
        if let window {
            let converted = window.convert(frame, from: nil)
            overlap = max(0, window.bounds.maxY - converted.minY)
            bottomSafe = window.safeAreaInsets.bottom
        } else {
            let screenH = UIScreen.main.bounds.height
            overlap = max(0, screenH - frame.origin.y)
            bottomSafe = 0
        }

        // Keyboard dismissed / off-screen: end frame sits at or below the bottom.
        let lift = max(0, overlap - bottomSafe)
        keyboardLift = lift > 10 ? lift : 0
    }

    private var chatTitle: String {
        if let id = viewModel.activeChatID,
           let item = history?.recents.first(where: { $0.id == id }),
           !item.title.isEmpty {
            return item.title
        }
        return "New chat"
    }

    /// Depth of the bound root navigation path (0 = chat is the visible root).
    private var navigationPathDepth: Int {
        path?.wrappedValue.count ?? 0
    }

    /// Binding for the coding-session launch alert (message + dismiss).
    private var sessionLaunchErrorBinding: Binding<Bool> {
        Binding(
            get: { sessionLaunchError != nil },
            set: { if !$0 { sessionLaunchError = nil } }
        )
    }

    private func bindAndLoad() {
        viewModel.state = state
        guard let history else { return }
        viewModel.history = history
        if let project, let chat {
            viewModel.loadProjectChat(project: project, chat: chat, from: history)
        } else if let active = history.activeChatID,
                  history.recents.contains(where: { $0.id == active }) {
            // Explicit open: New chat, sidebar recent, or Chats home — not cold launch.
            viewModel.loadChat(id: active, from: history)
        } else {
            // App open / no active chat → always a blank new chat page.
            viewModel.beginNewChat(in: history)
        }
    }

    /// Persist the open transcript, then auto-name it unless the user renamed it.
    private func persistAndAutoTitleOnLeave() {
        let leavingChatID = viewModel.activeChatID
        let leavingProjectID = viewModel.activeProjectID
        viewModel.persistNow()
        guard let history, let leavingChatID else { return }
        history.autoGenerateTitleIfNeeded(for: leavingChatID, projectID: leavingProjectID)
    }

    /// Remove unsent drafts from the sidebar / project list when leaving chat.
    private func discardBlankDraftIfNeeded() {
        guard let history else { return }
        if let project {
            history.discardActiveProjectChatIfBlank(projectID: project.id)
        } else {
            history.discardActiveIfBlank()
        }
    }

    private func projectPill(_ project: ProjectItem) -> some View {
        Button(action: popToProject) {
            HStack(spacing: 6) {
                Image(systemName: "archivebox")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
        // Tap the pill to pop back to the project detail. The chat view
        // is one level deep in the navigation stack (project -> chat),
        // so popping dismisses the chat and lands on the project.
        .accessibilityLabel("Go to project \(project.name)")
    }

    private func popToProject() {
        // Title before the stack pop so Recents / project list show a name
        // as soon as this chat is left (onDisappear also covers teardown).
        persistAndAutoTitleOnLeave()
        discardBlankDraftIfNeeded()
        // Prefer popping the navigation stack via the bound path; fall back
        // to the system dismiss action when no path is provided (e.g. the
        // root landing screen).
        if let path, !path.wrappedValue.isEmpty {
            path.wrappedValue.removeLast()
        }
    }

    private var errorBanner: some View {
        HStack(spacing: 10) {
            if viewModel.errorBannerAction != nil {
                Button(action: handleErrorBannerTap) {
                    errorBannerLabel
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens provider settings to add a model")
            } else {
                errorBannerLabel
            }

            Button { viewModel.clearError() } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var errorBannerLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(viewModel.error ?? "")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            if viewModel.errorBannerAction == .openProviderSettings {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func handleErrorBannerTap() {
        switch viewModel.errorBannerAction {
        case .openProviderSettings:
            viewModel.clearError()
            showProviderSettings = true
        case .none:
            break
        }
    }

    /// True when there are no real user messages yet. The single welcome
    /// message that `ChatViewModel` seeds is treated as part of the empty
    /// state so we can show the centered greeting.
    private var isEffectivelyEmpty: Bool {
        viewModel.messages.allSatisfy { $0.role == .assistant } &&
        viewModel.messages.count <= 1
    }

    // MARK: - Loading (resume large chat)

    /// Shown immediately when opening a big transcript so navigation isn't
    /// blocked while messages are converted for the list.
    private var chatLoadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Theme.accent)
                .scaleEffect(1.15)
            Text("Loading chat…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading chat")
    }

    // MARK: - Empty home (greeting)

    /// Fills the space above the composer and centers the greeting in it.
    /// Avoids dual expanding Spacers (which left a large dead zone under the
    /// nav / error banner, especially with the keyboard open). Does not own
    /// the composer — that lives as a sibling so it cannot be crushed here.
    private var emptyHome: some View {
        VStack(spacing: 0) {
            if viewModel.error != nil {
                errorBanner
            }
            greeting
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var greeting: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 18) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                Text(ChatGreeting.phrase(at: context.date))
                    .font(.system(size: 26, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .contentTransition(.opacity)
                    .id(ChatGreeting.phrase(at: context.date))
            }
            // Slight upward bias so the block sits closer to true visual center
            // once the composer (and keyboard) claim the bottom of the screen.
            .padding(.bottom, 28)
            .animation(.easeInOut(duration: 0.35), value: ChatGreeting.phrase(at: context.date))
        }
    }

    // MARK: - Message list + optional artifact split

    /// Chat transcript, optionally beside an open artifact panel (Claude-style).
    @ViewBuilder
    private var chatBodyWithOptionalArtifact: some View {
        if let artifact = state.openArtifact {
            GeometryReader { geo in
                let wide = geo.size.width >= 700
                if wide {
                    HStack(spacing: 0) {
                        messageList
                            .frame(maxWidth: .infinity)
                        Divider().overlay(Theme.separator)
                        ArtifactDetailView(artifact: artifact) {
                            state.dismissOpenArtifact()
                        }
                        .frame(width: min(420, geo.size.width * 0.48))
                    }
                } else {
                    // Phone: stack transcript under a sheet-like top panel, or show
                    // transcript with floating artifact full-height below a handle.
                    ZStack(alignment: .trailing) {
                        messageList
                        ArtifactDetailView(artifact: artifact) {
                            state.dismissOpenArtifact()
                        }
                        .frame(maxWidth: .infinity)
                        .background(Theme.background)
                        .transition(.move(edge: .trailing))
                    }
                }
            }
        } else {
            messageList
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        ChatMessageView(
                            message: message,
                            onCopy: { viewModel.copyMessage(message) },
                            onShare: { viewModel.shareMessage(message) },
                            onDelete: { viewModel.deleteMessage(message) },
                            onRegenerate: { Task { await viewModel.regenerateResponse(for: message) } },
                            isArtifactSource: isArtifactSource(message)
                        )
                        .id(message.id)
                    }
                    // Sentinel anchor at the very bottom. `defaultScrollAnchor`
                    // keeps this on-screen as the trailing message grows, so
                    // streaming text never falls off the bottom.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.streamTailAnchorID)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: viewModel.messages.count) {
                // Prefer explicit artifact scroll target over following the stream tail.
                if let target = state.scrollToMessageId {
                    withAnimation(.easeOut(duration: 0.35)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    DispatchQueue.main.async {
                        state.scrollToMessageId = nil
                    }
                    return
                }
                if let lastMessage = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
                // Final nudge to the sentinel tail once the message lands —
                // .defaultScrollAnchor only re-engages on size changes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(Self.streamTailAnchorID, anchor: .bottom)
                    }
                }
            }
            // `lastContentChangeToken` is bumped whenever the trailing message
            // grows (i.e. while the assistant is streaming). We use it as
            // an `onChange` trigger so the scroll view follows the stream
            // tail even though the message *count* never changes mid-response.
            // Without this, sending a message leaves the user looking at
            // the bottom of their own bubble while the assistant content
            // grows below the visible area — i.e. the "blank screen after
            // send" bug.
            .onChange(of: lastContentChangeToken) { _, _ in
                // Only follow the stream if the user is already at (or very
                // near) the bottom. Otherwise leave them where they are so
                // they can keep reading older messages while the response
                // streams in.
                guard state.scrollToMessageId == nil else { return }
                guard shouldFollowStreamTail else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.streamTailAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: state.scrollToMessageId) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if state.scrollToMessageId == target {
                        state.scrollToMessageId = nil
                    }
                }
            }
            .onAppear {
                if let target = state.scrollToMessageId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.easeOut(duration: 0.35)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        state.scrollToMessageId = nil
                    }
                }
            }
        }
    }

    /// Anchor id used by `messageList` to keep the bottom of the transcript
    /// pinned to the viewport as the trailing message grows.
    private static let streamTailAnchorID = "rs.stream.tail.anchor"

    /// Bumped whenever the trailing message grows (i.e. while the
    /// assistant is streaming). We use it as an `onChange` trigger so the
    /// scroll view follows the stream tail even though the message *count*
    /// never changes mid-response. Without this, sending a message leaves
    /// the user looking at the bottom of their own bubble while the
    /// assistant content grows below the visible area — i.e. the "blank
    /// screen after send" bug.
    private var lastContentChangeToken: String {
        viewModel.messages.last.map { msg in
            "\(msg.id)-\(msg.content.count)-\(msg.isStreaming)-\(msg.toolCalls?.count ?? 0)"
        } ?? ""
    }

    /// True when the scroll position is at (or within ~80pt of) the bottom
    /// of the content. Used to gate auto-follow during streaming so a user
    /// who has scrolled up to read older messages doesn't get yanked back
    /// to the tail every time a token lands.
    private var shouldFollowStreamTail: Bool {
        // The view-model exposes whether we're currently streaming. While
        // we are, the user almost always wants to follow. After streaming
        // ends, stop following so subsequent small layout shifts (image
        // attachment sizing, tool-card reveal) don't disturb the user.
        viewModel.messages.last?.isStreaming == true
    }

    private func isArtifactSource(_ message: ChatMessage) -> Bool {
        guard let art = state.openArtifact else { return false }
        if let mid = art.messageId { return message.id == mid }
        return message.role == .assistant && message.content == art.content
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if state.isLoadingLocalMetal {
                LocalMetalLoadProgressBanner(
                    progress: state.localMetalLoadProgress,
                    modelName: state.selectedModel.map { state.displayName(for: $0) },
                    style: .card
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let notice = state.memoryUnloadNotice, !notice.isEmpty {
                // Soft notice after iOS forced us to unload a multi-GB
                // vision tower. Distinct from `localMetalLoadError` so it
                // doesn't get cleared by the next load attempt and reads
                // as informational, not as an error.
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            } else if let err = state.localMetalLoadError, !err.isEmpty {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            composerSurface
        }
        .padding(.horizontal, 16)
        // Home-indicator gap when keyboard is down; tight gap when sitting on keys.
        .padding(.bottom, keyboardVisible ? 6 : 12)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: state.isLoadingLocalMetal)
        // Extend fill under the home indicator only when the keyboard is down
        // (with the keyboard up, the composer already sits on the key plane).
        .background {
            if keyboardVisible {
                Theme.background
            } else {
                Theme.background.ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private var composerSurface: some View {
        VStack(spacing: 8) {
            if viewModel.healthEnabled
                || viewModel.locationEnabled
                || viewModel.webSearchEnabled
                || viewModel.researchEnabled
                || studyMode
                || viewModel.guidedLearningEnabled
            {
                contextChips
            }

            // Top: text field on its own row — full width, room to breathe.
            TextField("Message RoamSocket", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.textPrimary)
                .frame(minHeight: 24, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if !viewModel.attachedImages.isEmpty {
                attachedImageStrip
            }

            // Photo-disabled hint — shown above the controls row when the
            // active on-device Metal model can't ingest images. Keeps the
            // user from tapping the (greyed) camera button and wondering why.
            if let reason = viewModel.photoDisabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }

            // Bottom: controls row — +, model pill, send.
            HStack(alignment: .center, spacing: 8) {
                // Plus: opens the AddToChat sheet
                Button(action: { viewModel.showAddToChatSheet = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)

                // Model pill — switches to a "+ Add a model" CTA when
                // no usable model is configured.
                ModelSelectorPill(
                    modelDisplayName: modelPillTitle,
                    onPick: { viewModel.showModelPicker = true },
                    onAddModel: { showProviderSettings = true }
                )

                Spacer(minLength: 0)

                // Camera — opens the system camera and attaches the photo to
                // this chat (no Vision analysis flow).
                //
                // Disabled when the active on-device model is text-only — the
                // MLX backend would crash feeding it images. Show a one-line
                // hint so the user knows why the button is grey.
                Button {
                    viewModel.showCamera = true
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(
                    viewModel.isLoadingChat
                        || viewModel.isProcessing
                        || !viewModel.selectedModelSupportsPhotos
                )
                .accessibilityLabel("Take photo")
                .accessibilityHint(
                    viewModel.photoDisabledReason
                        ?? "Capture a photo to attach to this chat"
                )

                // Gallery — opens PHPicker (system Photos) and attaches the
                // selected photos. Same vision-disabled rules as the camera
                // button: a text-only on-device model would crash inside MLX
                // if we fed it images, so we grey it out with the same hint.
                //
                // Also greyed when the composer is already at the staged-photo
                // cap so the user knows why before tapping.
                Button {
                    viewModel.showGallery = true
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(
                    viewModel.isLoadingChat
                        || viewModel.isProcessing
                        || !viewModel.selectedModelSupportsPhotos
                        || viewModel.attachedImages.count >= ChatViewModel.maxAttachedImages
                )
                .accessibilityLabel("Pick photos from library")
                .accessibilityHint(
                    viewModel.photoDisabledReason
                        ?? (viewModel.attachedImages.count >= ChatViewModel.maxAttachedImages
                            ? "Maximum \(ChatViewModel.maxAttachedImages) photos per message"
                            : "Choose photos to attach to this chat")
                )

                if hasText {
                    // Send — only when there is real input.
                    Button(action: sendTapped) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 36, height: 36)
                            .background(sendBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoadingChat || viewModel.isProcessing)
                    .accessibilityLabel("Send")
                } else {
                    // Empty composer: open live voice chat (Siri dictation + TTS).
                    Button {
                        showVoiceChat = true
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoadingChat || viewModel.isProcessing)
                    .accessibilityLabel("Voice chat")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Theme.separator, lineWidth: 1)
        )
    }

    /// Pending camera photos staged in the composer (tap x to remove).
    private var attachedImageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.attachedImages) { attachment in
                    if let image = UIImage(data: attachment.thumbnailData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    viewModel.removeAttachedImage(attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(Theme.surface)
                                        .background(Circle().fill(Color.black.opacity(0.55)))
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                                .accessibilityLabel("Remove photo")
                            }
                    }
                }
            }
        }
        .frame(height: 72)
    }

    /// Compact indicators for optional context attached on send.
    private var contextChips: some View {
        HStack(spacing: 8) {
            if studyMode {
                contextChip(
                    systemImage: "book.closed.fill",
                    imageColor: Theme.accent,
                    title: "Sources"
                )
            }
            if viewModel.guidedLearningEnabled {
                contextChip(
                    systemImage: "graduationcap.fill",
                    imageColor: Theme.accent,
                    title: "Guided learning",
                    dismissLabel: "Turn off Guided Learning"
                ) {
                    viewModel.guidedLearningEnabled = false
                }
            }
            if viewModel.researchEnabled {
                contextChip(
                    systemImage: "magnifyingglass",
                    imageColor: Theme.accent,
                    title: "Research",
                    dismissLabel: "Turn off Research"
                ) {
                    viewModel.researchEnabled = false
                    // Research implies web search; turning research off
                    // leaves simple web search as the user last set it.
                }
            } else if viewModel.webSearchEnabled {
                contextChip(
                    systemImage: "globe",
                    imageColor: Theme.accent,
                    title: "Web",
                    dismissLabel: "Turn off Web search"
                ) {
                    viewModel.webSearchEnabled = false
                }
            }
            if viewModel.healthEnabled {
                contextChip(
                    systemImage: "heart.fill",
                    imageColor: .pink,
                    title: "Health",
                    dismissLabel: "Turn off Health"
                ) {
                    Task { await viewModel.setHealthEnabled(false) }
                }
            }
            if viewModel.locationEnabled {
                contextChip(
                    systemImage: "location.fill",
                    imageColor: Theme.accent,
                    title: "Location",
                    dismissLabel: "Turn off Location"
                ) {
                    Task { await viewModel.setLocationEnabled(false) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func contextChip(
        systemImage: String,
        imageColor: Color,
        title: String,
        dismissLabel: String? = nil,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(imageColor)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dismissLabel ?? "Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surfaceElevated, in: Capsule())
        .accessibilityElement(children: onDismiss == nil ? .combine : .contain)
        .accessibilityLabel(Text(title))
    }

    private var modelPillTitle: String {
        // Strip the trailing effort token (e.g. "Sonnet 5 (High)") to
        // match the iOS chat composer. The pill itself decides what to
        // show when there's no model at all — empty string here lets it
        // switch into the "+ Add a model" CTA.
        // Use displayName(for:) so aliases + Local Metal pretty names match the picker.
        if let model = state.selectedModel {
            return stripEffort(from: state.displayName(for: model))
        }
        return ""
    }

    private func stripEffort(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for suffix in Effort.allCases.reversed() {
            let token = " " + suffix.displayName
            if trimmed.lowercased().hasSuffix(token.lowercased()) {
                return String(trimmed.dropLast(token.count))
            }
        }
        return trimmed
    }

    private var hasText: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !viewModel.attachedImages.isEmpty
    }

    private var sendBackground: some ShapeStyle {
        if !hasText {
            return AnyShapeStyle(Theme.surfaceElevated)
        } else {
            // Orange gradient like the screenshot.
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Theme.accent, Theme.accent.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    /// Routes a Send tap to either a coding session (when the user has paired
    /// a server + selected a repo + has a model with an API key) or the
    /// provider-backed chat as before.
    private func sendTapped() {
        let text = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !viewModel.attachedImages.isEmpty else { return }
        // Photos always go through the provider chat path — never a coding session.
        if viewModel.attachedImages.isEmpty,
           let config = SessionLauncher.makeConfig(in: state, task: text) {
            viewModel.inputText = ""
            sessionConfig = config
        } else {
            Task { await viewModel.sendMessage() }
        }
    }
}

/// Time-of-day empty-state greetings. Phrases rotate by hour (and day) so the
/// home screen doesn’t always say the same thing.
enum ChatGreeting {
    enum Period: CaseIterable {
        case lateNight   // 0–4
        case earlyMorning // 5–8
        case morning     // 9–11
        case afternoon   // 12–16
        case evening     // 17–20
        case night       // 21–23

        static func at(_ date: Date, calendar: Calendar = .current) -> Period {
            let hour = calendar.component(.hour, from: date)
            switch hour {
            case 0..<5: return .lateNight
            case 5..<9: return .earlyMorning
            case 9..<12: return .morning
            case 12..<17: return .afternoon
            case 17..<21: return .evening
            default: return .night
            }
        }

        var phrases: [String] {
            switch self {
            case .lateNight:
                return [
                    "Still up? The bugs never sleep either.",
                    "Midnight oil: officially lit.",
                    "Quiet hours. Loud ideas.",
                    "3 a.m. is a perfectly normal time to ship.",
                    "The CI ghosts are friendlier at this hour.",
                    "Coffee optional. Courage required.",
                    "Night shift for code that dreams in stack traces.",
                    "Only the terminal and the moon are online.",
                ]
            case .earlyMorning:
                return [
                    "Good morning. Let’s invent something small.",
                    "Fresh day, clean branch, questionable coffee.",
                    "Boot sequence complete. What’s first?",
                    "Sunrise commits hit different.",
                    "The early bird gets the green build.",
                    "Stretch, hydrate, then refactor.",
                    "Morning brain: surprisingly good at naming things.",
                    "Warming up the compilers… and the optimism.",
                ]
            case .morning:
                return [
                    "Ready when you are.",
                    "Inbox zero can wait. Ideas can’t.",
                    "What are we building today?",
                    "Mid-morning is prime time for clever hacks.",
                    "Plotting greatness between meetings.",
                    "Let’s turn that half-baked thought into a PR.",
                    "Your cursor is blinking. So is destiny.",
                    "Ship small, ship often, ship with flair.",
                ]
            case .afternoon:
                return [
                    "Afternoon check-in. How’s the stack feeling?",
                    "Post-lunch productivity? We can make it happen.",
                    "The day is half over. The fun is not.",
                    "Time for a spicy little feature.",
                    "If it compiles, we celebrate. If not, we learn.",
                    "Standing by for your next brilliant digression.",
                    "Let’s make the afternoon count for something mergeable.",
                    "Snack break over. Idea break starts now.",
                ]
            case .evening:
                return [
                    "Clocking in for the evening shift.",
                    "Golden hour for golden code.",
                    "Evening mode: fewer meetings, more commits.",
                    "The day wind-down… or the real work begins.",
                    "Twilight and type errors—classic combo.",
                    "Let’s close a loop before dinner.",
                    "Side project energy detected.",
                    "Soft light. Sharp diffs.",
                ]
            case .night:
                return [
                    "Night mode engaged. What shall we cook up?",
                    "Stars out. Bugs in. Your move.",
                    "The perfect hour for a reckless rewrite.",
                    "Quiet keyboard. Loud ambition.",
                    "One more feature before the night ends.",
                    "Let’s leave tomorrow’s self a nicer codebase.",
                    "Dark theme. Bright ideas.",
                    "Last call for elegant solutions.",
                ]
            }
        }
    }

    /// Stable-but-rotating pick: changes each hour, and shifts day-to-day.
    static func phrase(at date: Date = Date(), calendar: Calendar = .current) -> String {
        let period = Period.at(date, calendar: calendar)
        let phrases = period.phrases
        guard !phrases.isEmpty else { return "Ready when you are." }

        let hour = calendar.component(.hour, from: date)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let year = calendar.component(.year, from: date)
        // Mix day + hour so the same hour tomorrow isn’t the same line.
        let seed = year &* 1000 &+ dayOfYear &* 24 &+ hour
        let index = abs(seed) % phrases.count
        return phrases[index]
    }
}

#Preview {
    ChatView()
}
