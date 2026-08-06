import SwiftUI
import UIKit
import AnyProvCore

/// The coding-session transcript: streamed assistant text, tool cards, diffs,
/// permission prompts, and a Create-PR action.
struct SessionView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openURL) private var openURL
    @StateObject private var model: SessionViewModel
    @State private var followUp = ""
    @State private var showGitSheet = false
    /// Which git steps the sheet will run after the user confirms.
    @State private var pendingGitAction: GitSheetAction = .all
    @State private var showTerminal = false
    @State private var showFiles = false
    @State private var showPorts = false
    @State private var showModelPicker = false
    @State private var showPermissionSheet = false
    @State private var showProviderSettings = false
    @State private var detailTool: SessionViewModel.Item?
    @State private var browserBusy = false

    private enum GitSheetAction: String, Identifiable {
        case commit, push, pr, all
        var id: String { rawValue }

        var title: String {
            switch self {
            case .commit: return "Commit"
            case .push: return "Push"
            case .pr: return "Create PR"
            case .all: return "Done · Commit · Push · PR"
            }
        }

        var needsMessage: Bool {
            switch self {
            case .commit, .all, .pr: return true
            case .push: return false
            }
        }

        var commit: Bool {
            switch self {
            case .commit, .all: return true
            case .push: return false
            // PR flow commits if there are local changes (server skips when clean).
            case .pr: return true
            }
        }

        var push: Bool {
            switch self {
            case .push, .pr, .all: return true
            case .commit: return false
            }
        }

        var openPr: Bool {
            switch self {
            case .pr, .all: return true
            case .commit, .push: return false
            }
        }
    }

    private let config: SessionConfig

    init(config: SessionConfig) {
        self.config = config
        _model = StateObject(wrappedValue: SessionViewModel(config: config, client: ServerClient()))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                EnvironmentConnectionPill(environment: config.environment)
                if let status = model.connectionStatusLine {
                    Text(status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.connectionError != nil ? Color.red.opacity(0.9) : Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }
                transcript
                if let permission = model.pendingPermission {
                    permissionBar(permission)
                }
                inputArea
            }
        }
        .navigationTitle(config.repo.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.state = state
            model.loadPersistedTranscript(from: state.codeSessionStore)
        }
        .onDisappear {
            model.persistTranscript()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.hasDiffs {
                    let stats = model.totalDiffStats
                    Text("+\(stats.added) −\(stats.removed)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.selection)
                }
                Button {
                    openGitAction()
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(Theme.textPrimary)
                }
                .accessibilityLabel(model.prURL != nil ? "Open pull request" : "Git · \(model.workBranch)")

                // Far-right workspace menu (shell / files / ports).
                Menu {
                    Button {
                        showTerminal = true
                    } label: {
                        Label("Shell", systemImage: "terminal")
                    }
                    Button {
                        showFiles = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    if model.hasWebPreview {
                        Button {
                            Task { await openBrowserPreview() }
                        } label: {
                            Label(
                                browserBusy ? "Opening preview…" : "Browser",
                                systemImage: "safari"
                            )
                        }
                        .disabled(browserBusy)
                    }
                    Button {
                        showPorts = true
                    } label: {
                        Label("Open ports", systemImage: "network")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(Theme.textPrimary)
                }
                .accessibilityLabel("Workspace menu")
            }
        }
        .sheet(isPresented: $showTerminal) {
            NavigationStack {
                TerminalPaneView(sessionId: model.sessionID)
                    .navigationTitle("Shell")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showTerminal = false }
                        }
                    }
            }
            .environmentObject(state)
            .preferredColorScheme(.dark)
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showFiles) {
            NavigationStack {
                FileExplorerView(sessionId: model.sessionID)
                    .navigationTitle("Files")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showFiles = false }
                        }
                    }
            }
            .environmentObject(state)
            .preferredColorScheme(.dark)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPorts) {
            NavigationStack {
                PortManagerView(sessionId: model.sessionID)
                    .navigationTitle("Open ports")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showPorts = false }
                        }
                    }
            }
            .environmentObject(state)
            .preferredColorScheme(.dark)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showGitSheet) { gitSheet }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet()
        }
        .sheet(isPresented: $showProviderSettings) {
            // Reuse the existing settings screen so the providers UI stays
            // single-sourced — same body as the entry from the home screen.
            // Land directly on the providers section when the user came
            // from the "+ Add a model" pill so they don't have to tap
            // through again.
            AppSettingsView(initialFocus: .providers)
        }
        .sheet(isPresented: $showPermissionSheet) {
            PermissionModeSheet(selection: permissionBinding)
        }
        .sheet(item: $detailTool) { item in
            if case let .tool(_, tool, summary, ok, output) = item {
                ToolDetailSheet(tool: tool, summary: summary, ok: ok, output: output)
            }
        }
        .onChange(of: model.prURL) { _, url in
            if let url { openURL(url) }
        }
        .onAppear {
            model.state = state
            model.start()
        }
        .onDisappear { model.stop() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.items) { item in
                        row(for: item).id(item.id)
                    }
                    if let error = model.connectionError {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .onChange(of: model.items.count) { _, _ in
                if let last = model.items.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: SessionViewModel.Item) -> some View {
        switch item {
        case let .user(_, text):
            SessionUserBubble(text: text)

        case let .assistant(_, text):
            SessionAssistantMessage(
                text: text,
                alwaysExpandThinking: state.alwaysExpandThinking
            )

        case let .tool(_, tool, summary, ok, output):
            ToolCard(
                tool: tool,
                summary: summary,
                ok: ok,
                output: output,
                onOpenDetail: { detailTool = item }
            )

        case let .diff(_, path, patch, added, removed):
            DiffCard(path: path, patch: patch, added: added, removed: removed)

        case let .notice(_, text):
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionBar(_ permission: SessionViewModel.PendingPermission) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow \(permission.tool)?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(permission.summary)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Deny") { model.respond(to: permission, allow: false) }
                .buttonStyle(.bordered)
            Button("Allow") { model.respond(to: permission, allow: true) }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Theme.surfaceElevated)
    }

    /// Input area split into two rows: the chat text box on top, then a
    /// second row with the action pills and send button. Matches the
    /// prompt lives above the
    /// controls.
    private var inputArea: some View {
        VStack(spacing: 8) {
            messageBox
            actionRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.background)
    }

    private var messageBox: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                "",
                text: $followUp,
                prompt: Text(composerPrompt)
                    .foregroundColor(Theme.textTertiary),
                axis: .vertical
            )
            .font(.system(size: 16))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...4)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!model.canAcceptInput)
            .onChange(of: model.isRunning) { _, isRunning in
                // When the agent transitions from running → idle, flush
                // any queued follow-up so the user doesn't have to retap.
                if !isRunning { model.sendQueuedMessageIfNeeded() }
            }

            trailingSendButton
        }
    }

    private var composerPrompt: String {
        if !model.isSessionReady {
            return model.connectionError != nil ? "Not connected…" : "Connecting to desktop…"
        }
        if model.isRunning {
            return "Queue for after this turn…"
        }
        return "Reply…"
    }

    private var trailingSendButton: some View {
        Group {
            if model.connectionError != nil {
                // Same slot as Send — red alert; tap retries the desktop link.
                Button {
                    model.retryConnection()
                } label: {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.red.opacity(0.9), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Connection failed. Tap to retry.")
                .help(model.connectionError ?? "Connection failed")
            } else if !model.isSessionReady {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 40, height: 40)
            } else if model.isRunning {
                if canSend {
                    Button(action: queueFollowUp) {
                        Image(systemName: "text.append")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Queue message")
                } else {
                    Button { model.interrupt() } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                }
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(canSend ? Theme.background : Theme.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(canSend ? Theme.accent : Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            gitActionRow

            HStack(spacing: 8) {
                Button { /* TODO: attach file / @-mention */ } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surface, in: Circle())
                }
                .buttonStyle(.plain)

                ModelSelectorPill(
                    modelDisplayName: modelPillTitle,
                    onPick: { showModelPicker = true },
                    onAddModel: { showProviderSettings = true }
                )
                permissionPill
                Spacer(minLength: 0)

                Menu {
                    Button { showTerminal = true } label: {
                        Label("Shell", systemImage: "terminal")
                    }
                    Button { showFiles = true } label: {
                        Label("Files", systemImage: "folder")
                    }
                    if model.hasWebPreview {
                        Button {
                            Task { await openBrowserPreview() }
                        } label: {
                            Label("Browser", systemImage: "safari")
                        }
                    }
                    Button { openGitSheet(.all) } label: {
                        Label("Finish · PR", systemImage: "checkmark.seal")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surface, in: Circle())
                }
            }
        }
    }

    private func openGitAction() {
        if let url = model.prURL {
            openURL(url)
            return
        }
        // No PR yet — open the git sheet for commit / push / PR (branch is already per-session).
        openGitSheet(.all)
    }

    private func openBrowserPreview() async {
        browserBusy = true
        defer { browserBusy = false }
        await model.refreshPorts()
        guard let port = model.primaryWebPort else { return }
        // Prefer a tunnel so the phone can reach the desktop off-LAN.
        if let tunneled = await model.exposePortForPreview(port) {
            openURL(tunneled)
            return
        }
        if let url = model.webPreviewURL {
            openURL(url)
        }
    }

    /// Instant commit / push / PR controls (publish strip).
    private var gitActionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                liveGitStatusBadge
                gitChip("Commit", systemImage: "checkmark.circle", action: .commit)
                gitChip("Push", systemImage: "arrow.up.to.line", action: .push)
                gitChip("PR", systemImage: "arrow.triangle.branch", action: .pr)
                gitChip("Done", systemImage: "checkmark.seal", action: .all, emphasized: true)
            }
        }
    }

    /// Same style of ahead / blocked / clean pill that used to sit on the
    /// Code home session list — now lives next to publish actions.
    private var liveGitStatusBadge: some View {
        SessionGitStatusBadge.live(
            isRunning: model.isRunning,
            hasDiffs: model.hasDiffs,
            hasPR: model.prURL != nil,
            needsInput: model.pendingPermission != nil
        )
    }

    private func gitChip(
        _ title: String,
        systemImage: String,
        action: GitSheetAction,
        emphasized: Bool = false
    ) -> some View {
        Button {
            openGitSheet(action)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(emphasized ? Theme.background : Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                emphasized ? Theme.accent : Theme.surfaceElevated,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isPublishing || !model.isSessionReady)
        .opacity(model.isPublishing || !model.isSessionReady ? 0.45 : 1)
    }

    private func openGitSheet(_ action: GitSheetAction) {
        pendingGitAction = action
        showGitSheet = true
        if action.needsMessage {
            model.prepareCommitMessage(generateWithAI: true)
        }
    }

    private var permissionPill: some View {
        Button {
            if !model.isRunning { showPermissionSheet = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: state.permissionMode.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(state.permissionMode == .acceptEdits ? "Accept edits" : state.permissionMode.displayName)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(model.isRunning ? Theme.textTertiary : Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning)
        .help(model.isRunning ? "Mode is locked while a session is running" : "Change permission mode")
    }

    /// Always show the mode captured in the `SessionConfig` once the session
    /// starts, even if `state.permissionMode` is changed elsewhere. This
    /// keeps the on-screen pill honest about the mode the server received.
    private var permissionBinding: Binding<PermissionMode> {
        Binding(
            get: { model.isRunning ? config.permissionMode : state.permissionMode },
            set: { state.permissionMode = $0 }
        )
    }

    private var modelPillTitle: String {
        if let name = state.selectedModel?.displayName {
            return Self.stripEffort(from: name)
        }
        return "Select a model"
    }

    private static func stripEffort(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for suffix in Effort.allCases.reversed() {
            let token = " " + suffix.displayName
            if trimmed.lowercased().hasSuffix(token.lowercased()) {
                return String(trimmed.dropLast(token.count))
            }
        }
        return trimmed
    }

    private var gitSheet: some View {
        NavigationStack {
            Form {
                if pendingGitAction.needsMessage {
                    Section {
                        ZStack(alignment: .topLeading) {
                            if model.commitMessage.isEmpty && model.isGeneratingCommitMessage {
                                Text("Generating commit message…")
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            TextField("Commit message", text: $model.commitMessage, axis: .vertical)
                                .lineLimit(2...6)
                        }
                        Button {
                            Task { await model.generateCommitMessageWithAI() }
                        } label: {
                            HStack {
                                if model.isGeneratingCommitMessage {
                                    ProgressView()
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(model.isGeneratingCommitMessage ? "Generating…" : "Regenerate with AI")
                            }
                        }
                        .disabled(model.isGeneratingCommitMessage)
                    } header: {
                        Text("Commit message")
                    } footer: {
                        Text(gitSheetFooter)
                    }
                } else {
                    Section {
                        Text("Pushes the current work branch to origin.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if model.hasDiffs {
                    Section("Local changes") {
                        let stats = model.totalDiffStats
                        Text("+\(stats.added) −\(stats.removed) across session diffs")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Theme.selection)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(pendingGitAction.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showGitSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pendingGitAction.title) {
                        confirmGitAction()
                    }
                    .disabled(gitConfirmDisabled)
                    .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private var gitSheetFooter: String {
        switch pendingGitAction {
        case .commit:
            return "Stages all changes and creates a commit on the work branch."
        case .push:
            return "Pushes the work branch to GitHub."
        case .pr:
            return "Commits if needed, pushes, then opens GitHub’s create-PR page."
        case .all:
            return "Finishes this session: commits, pushes the session branch, and opens a pull request. Does not merge."
        }
    }

    private var gitConfirmDisabled: Bool {
        if model.isPublishing { return true }
        if pendingGitAction.needsMessage {
            return model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || model.isGeneratingCommitMessage
        }
        return false
    }

    private func confirmGitAction() {
        let message = model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = pendingGitAction
        showGitSheet = false
        model.gitPublish(
            message: message,
            commit: action.commit,
            push: action.push,
            openPr: action.openPr
        )
    }

    private var canSend: Bool {
        !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.sendUserMessage(text)
        followUp = ""
    }

    private func queueFollowUp() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.queueMessage(text)
        followUp = ""
    }
}

/// Outgoing user message — same bubble treatment as chat.
private struct SessionUserBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 17))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 20))
            .frame(maxWidth: 320, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Assistant text with thinking collapsed behind a disclosure (matches chat).
private struct SessionAssistantMessage: View {
    let text: String
    let alwaysExpandThinking: Bool

    @State private var thinkingExpandedOverride: Bool?

    private var thinkingExpanded: Bool {
        thinkingExpandedOverride ?? alwaysExpandThinking
    }

    private var resolved: (thinking: String?, content: String) {
        let parsed = ThinkingExtractor.extract(from: text)
        return (parsed.thinking, parsed.content)
    }

    var body: some View {
        let resolved = resolved
        return VStack(alignment: .leading, spacing: 12) {
            if let thinking = resolved.thinking, !thinking.isEmpty {
                ThinkingBlock(
                    text: thinking,
                    expanded: thinkingExpanded,
                    onToggle: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            thinkingExpandedOverride = !thinkingExpanded
                        }
                    }
                )
            }

            if !resolved.content.isEmpty {
                MarkdownContentView(text: resolved.content, fontSize: 17)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Collapsible tool-call card. Summary row is always visible; command output
/// stays collapsed until the user taps to expand. Long-press opens full detail.
private struct ToolCard: View {
    let tool: String
    let summary: String
    let ok: Bool?
    let output: String?
    var onOpenDetail: (() -> Void)? = nil
    @State private var expanded = false

    private var hasOutput: Bool {
        guard let output else { return false }
        return !output.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard hasOutput else {
                    onOpenDetail?()
                    return
                }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(summary)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(expanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if hasOutput {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasOutput
                ? (expanded ? "Collapse command output" : "Expand command output")
                : summary)
            .accessibilityHint(hasOutput ? "Shows the tool’s full output" : "No output yet")

            if expanded, let output, !output.isEmpty {
                Text(output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onLongPressGesture(minimumDuration: 0.4) {
            onOpenDetail?()
        }
        .contextMenu {
            if onOpenDetail != nil {
                Button {
                    onOpenDetail?()
                } label: {
                    Label("View details", systemImage: "doc.text.magnifyingglass")
                }
            }
            if hasOutput, let output {
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = output
                    #endif
                } label: {
                    Label("Copy output", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var statusIcon: String {
        switch ok {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "xmark.circle.fill"
        case .none: return "circle.dotted"
        }
    }
    private var statusColor: Color {
        switch ok {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return Theme.textTertiary
        }
    }
}

/// Detail sheet for a single tool invocation. Shows the command/summary
/// at the top and the full output (with syntax-style highlighting for
/// `git`-style output) below.
private struct ToolDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tool: String
    let summary: String
    let ok: Bool?
    let output: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Command")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if let ok {
                            Text(ok ? "OK" : "Failed")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background((ok ? Color.green : Color.red).opacity(0.2), in: Capsule())
                                .foregroundStyle(ok ? .green : .red)
                        }
                    }
                    Text(displayName)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    if let output, !output.isEmpty {
                        Text("Output")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(output.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                    Text(String(line))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(color(for: String(line)))
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(12)
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("No output yet.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle(toolLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var toolLabel: String {
        switch tool {
        case "bash": return "Bash"
        case "read_file", "write_file", "edit_file": return "File"
        default: return tool.capitalized
        }
    }

    private var displayName: String {
        // The summary field carries the human summary; the raw command is
        // in the `input` blob stored on the model. For now we just show
        // the summary.
        summary
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("On branch ") || line.hasPrefix("----") { return Theme.textSecondary }
        if line.contains("nothing to commit") || line.contains("working tree clean") { return Theme.textSecondary }
        return Theme.textPrimary
    }
}

/// A unified-diff card with colorized lines.
private struct DiffCard: View {
    let path: String
    let patch: String
    let added: Int
    let removed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(path)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("+\(added) −\(removed)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.selection)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(String(line))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: String(line)))
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return Theme.selection }
        return Theme.textSecondary
    }
}
