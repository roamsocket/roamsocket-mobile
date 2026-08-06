import SwiftUI
import AnyProvCore

/// Main chat view:
///  * On a fresh / empty chat, shows a centered greeting like
///    "Clocking in for the evening shift." with a centered asterism glyph.
///  * Otherwise renders a vertically scrolling message list.
///  * The bottom composer holds a `+` button, a model pill, a mic, and a
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

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            Group {
                if isEffectivelyEmpty {
                    emptyHome
                } else {
                    messageList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Pin the composer to the bottom safe area so it stays above the home
        // indicator *and* the keyboard. Putting it in the main VStack let
        // emptyHome's expanding frame crush / cover it when the keyboard opens.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .onAppear { bindAndLoad() }
        .onChange(of: resumeToken) { _ in bindAndLoad() }
        .onDisappear { viewModel.persistNow() }
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
                }
            }
        }
        .sheet(isPresented: $viewModel.showConnectorsView) {
            ConnectorsView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showModelPicker) {
            ModelPickerSheet()
        }
        .sheet(isPresented: $showProviderSettings) {
            AppSettingsView(initialFocus: .providers)
        }
        .fullScreenCover(item: $sessionConfig) { config in
            NavigationStack {
                SessionView(config: config)
            }
        }
    }

    private var chatTitle: String {
        if let id = viewModel.activeChatID,
           let item = history?.recents.first(where: { $0.id == id }),
           !item.title.isEmpty {
            return item.title
        }
        return "New chat"
    }

    private func bindAndLoad() {
        viewModel.state = state
        guard let history else { return }
        viewModel.history = history
        if let project, let chat {
            viewModel.loadProjectChat(project: project, chat: chat, from: history)
        } else if let active = history.activeChatID {
            viewModel.loadChat(id: active, from: history)
        } else if !history.recents.isEmpty, let first = history.recents.first {
            // Resume last chat on cold launch.
            viewModel.loadChat(id: first.id, from: history)
        } else {
            viewModel.beginNewChat(in: history)
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

    // MARK: - Empty home (greeting)

    /// Fills the space above the composer and centers the greeting in it.
    /// Avoids dual expanding Spacers (which left a large dead zone under the
    /// nav / error banner, especially with the keyboard open).
    private var emptyHome: some View {
        VStack(spacing: 0) {
            if viewModel.error != nil {
                errorBanner
            }
            greeting
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var greeting: some View {
        VStack(spacing: 18) {
            AsterismGlyph()
                .frame(width: 56, height: 56)
            Text("Clocking in for the evening shift.")
                .font(.system(size: 26, weight: .regular, design: .serif))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        // Slight upward bias so the block sits closer to true visual center
        // once the composer (and keyboard) claim the bottom of the screen.
        .padding(.bottom, 28)
    }

    // MARK: - Message list

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
                            onRegenerate: { Task { await viewModel.regenerateResponse(for: message) } }
                        )
                        .id(message.id)
                    }

                    if viewModel.isProcessing {
                        ProcessingIndicator()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let lastMessage = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            composerSurface
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 8)
        // Extend fill under the home indicator so list content doesn't peek through.
        .background(Theme.background.ignoresSafeArea(edges: .bottom))
    }

    private var composerSurface: some View {
        VStack(spacing: 8) {
            if viewModel.healthEnabled {
                healthContextChip
            }

            // Top: text field on its own row — full width, room to breathe.
            TextField("Message AnyProv Code", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.textPrimary)
                .frame(minHeight: 24, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            // Bottom: controls row — +, model pill, mic, send.
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

                // Mic
                Button(action: {}) {
                    Image(systemName: "mic")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)

                // Send button: when there's text, show an up arrow; when empty, show the
                // voice waveform. Tapping either does the appropriate action — text goes
                // through `sendTapped` (which routes to a coding session when the user
                // has paired a server + selected a repo + model); the mic is a no-op
                // placeholder for now (voice input is a separate feature).
                Button(action: sendTapped) {
                    Image(systemName: hasText ? "arrow.up" : "waveform")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(sendBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!hasText)
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

    /// Compact indicator that Apple Health context will be attached on send.
    private var healthContextChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.pink)
            Text("Health")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            Button {
                Task { await viewModel.setHealthEnabled(false) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn off Health")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surfaceElevated, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelPillTitle: String {
        // Strip the trailing effort token (e.g. "Sonnet 5 (High)") to
        // match the iOS chat composer. The pill itself decides what to
        // show when there's no model at all — empty string here lets it
        // switch into the "+ Add a model" CTA.
        if let name = state.selectedModel?.displayName {
            return stripEffort(from: name)
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
        guard !text.isEmpty else { return }
        if let config = SessionLauncher.makeConfig(in: state, task: text) {
            viewModel.inputText = ""
            sessionConfig = config
        } else {
            Task { await viewModel.sendMessage() }
        }
    }
}

/// Processing indicator shown while AI is generating.
struct ProcessingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
            Text("Thinking...")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Centered accent glyph used on the empty chat home.
struct AsterismGlyph: View {
    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 4, height: 22)
                    .offset(y: -16)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
            Circle()
                .fill(Theme.accent)
                .frame(width: 6, height: 6)
        }
        .frame(width: 56, height: 56)
        .compositingGroup()
    }
}

#Preview {
    ChatView()
}
