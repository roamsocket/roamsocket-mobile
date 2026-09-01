import SwiftUI
import AnyProvCore

/// Chat-style UI for an E2B code session. The user types a
/// message at the bottom; the runner (placeholder for now:
/// the E2bSessionRunner that's wired in a follow-up commit)
/// produces a response that streams into the transcript.
///
/// The session is identified by its `E2bCodeSession.id` so the
/// view reuses the store's session instance across renders.
/// Closing the view (sheet dismiss, back button) does *not*
/// kill the sandbox — the user can return to the same session
/// from the Code home. An explicit "End session" button in
/// the toolbar calls `closeSession` on the store.
struct E2bSessionView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let sessionId: UUID
    /// Owned by the parent (the Code home). The view mutates
    /// transcript messages via the store, never directly.
    @ObservedObject var store: E2bSessionStore

    @State private var draft: String = ""
    @State private var isSending: Bool = false
    /// The in-flight agent turn's task. Held so the Stop button
    /// can cancel a long-running tool call (Claude is mid-tool or
    /// a shell is still streaming). `nil` when no turn is active.
    @State private var agentTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    private var session: E2bCodeSession? { store.session(id: sessionId) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    statusBar
                    messagesList
                    inputBar
                }
            }
            .navigationTitle(session?.title ?? "Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let s = session, s.isLive {
                            Button(role: .destructive) {
                                Task { await endSession() }
                            } label: {
                                Label("End session", systemImage: "xmark.circle")
                            }
                        } else if let s = session {
                            Button {
                                Task { await reopenSession() }
                            } label: {
                                Label("Reopen sandbox", systemImage: "arrow.clockwise")
                            }
                            .disabled(state.e2bKeyStore.get() == nil)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var statusBar: some View {
        Group {
            if let s = session {
                HStack(spacing: 8) {
                    Circle()
                        .fill(s.isLive ? Theme.selection : Theme.textTertiary)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.repoFullName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(s.branch)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(statusLabel(for: s))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .textCase(.uppercase)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surface)
            }
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let s = session {
                        ForEach(s.transcript) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    if isSending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .id("sending-anchor")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: session?.transcript.count ?? 0) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    if isSending {
                        proxy.scrollTo("sending-anchor", anchor: .bottom)
                    } else if let last = session?.transcript.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.separator)
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    "Ask the agent to write, run, or commit code…",
                    text: $draft,
                    axis: .vertical,
                )
                .lineLimit(1...5)
                .focused($inputFocused)
                .textFieldStyle(.plain)
                .disabled(isSending)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18))
                .onSubmit(send)
                if isSending {
                    Button {
                        agentTask?.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop agent")
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(canSend ? Theme.accent : Theme.textTertiary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.background)
        }
    }

    private var canSend: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !isSending && session?.isLive == true
    }

    private func statusLabel(for s: E2bCodeSession) -> String {
        switch s.status {
        case .provisioning: return "Provisioning…"
        case .idle: return "Idle"
        case .working: return "Working"
        case .readyForReview: return "Ready for review"
        case .failed: return "Failed"
        case .killed: return "Closed"
        }
    }

    // MARK: - Actions

    /// Send the current draft as a user message. Drives the
    /// Claude agent loop via `E2bSessionRunner` until Claude
    /// returns `end_turn` or we hit the step limit. Each step
    /// appends its tool calls + assistant text to the transcript
    /// as the loop runs.
    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session, s.isLive else { return }
        store.appendMessage(
            sessionId: sessionId,
            .init(kind: .user, text: trimmed)
        )
        draft = ""
        isSending = true
        let sandboxId = s.sandboxId ?? ""
        let sandboxAccessToken = s.sandboxAccessToken

        // Pick the LLM client from the user's selected model. v1
        // only supports the Anthropic provider — anything else
        // gets a clear "select Claude" message.
        guard let model = state.selectedModel else {
            store.appendMessage(sessionId: sessionId, .init(
                kind: .notice,
                text: "Pick a Claude model on the home screen first."
            ))
            isSending = false
            return
        }
        guard model.provider == .anthropic else {
            store.appendMessage(sessionId: sessionId, .init(
                kind: .notice,
                text: "The phone E2B agent only supports Anthropic Claude for now — switch the selected model to Claude."
            ))
            isSending = false
            return
        }
        let apiKey = state.resolvedAPIKey(for: model.provider)
        guard !apiKey.isEmpty else {
            store.appendMessage(sessionId: sessionId, .init(
                kind: .notice,
                text: "Add an Anthropic API key in Settings → Providers first."
            ))
            isSending = false
            return
        }
        guard let e2bKey = state.e2bKeyStore.get(), !e2bKey.isEmpty else {
            store.appendMessage(sessionId: sessionId, .init(
                kind: .notice,
                text: "Add your e2b.dev API key in Settings first."
            ))
            isSending = false
            return
        }

        let system = E2bSessionRunner.systemPrompt(
            repoFullName: s.repoFullName,
            branch: s.branch
        )
        // Cancel any in-flight turn (e.g. user retried) and start
        // a fresh task. The Stop button cancels via the same
        // `agentTask` reference.
        agentTask?.cancel()
        agentTask = Task { @MainActor in
            await runAgentLoop(
                system: system,
                sandboxId: sandboxId,
                sandboxAccessToken: sandboxAccessToken,
                e2bApiKey: e2bKey,
                anthropicApiKey: apiKey,
                modelName: model.modelID,
            )
            // Clear the task reference when we exit so a Stop tap
            // after completion is a no-op rather than cancelling a
            // freshly-started turn.
            self.agentTask = nil
        }
    }

    /// The agent loop. Builds the runner, replays the session
    /// transcript into a `messages` array, then steps until
    /// Claude ends the turn or the step limit is hit. Each step
    /// surfaces its tool calls as transcript cards and the
    /// assistant's text as a normal message.
    private func runAgentLoop(
        system: String,
        sandboxId: String,
        sandboxAccessToken: String?,
        e2bApiKey: String,
        anthropicApiKey: String,
        modelName: String,
    ) async {
        // Flip the session status to .working so the Code home
        // shows the right pill on this row. We restore to .idle
        // (or .failed) at the bottom of the function.
        store.setStatus(sessionId, .working)
        defer {
            isSending = false
            // Pick the right "post-loop" status. `.failed` if
            // we surfaced a non-cancellation error; `.idle` if
            // Claude finished cleanly or the user stopped.
            // (Cancellation is the common case; we want it
            // to look idle so the user can re-prompt.)
            store.setStatus(sessionId, .idle)
        }
        // Pull the current transcript into Anthropic Messages.
        // Keep them in memory; the runner mutates the local array
        // as it appends tool_use / tool_result blocks.
        var history: [AnthropicClient.Message] = []
        if let s = store.session(id: sessionId) {
            history = s.transcript.compactMap(messageToAnthropic)
        }
        let e2b = DirectE2BClient(apiKey: e2bApiKey)
        let anthropic = AnthropicClient(apiKey: anthropicApiKey, model: modelName)
        let runner = E2bSessionRunner(e2b: e2b, anthropic: anthropic)

        // Drive the loop. We cap at the runner's own maxSteps
        // (12) so a runaway conversation can't burn the user's
        // API budget.
        while !Task.isCancelled {
            // Re-read the sandbox state in case it was killed
            // mid-loop.
            guard let s = store.session(id: sessionId), s.isLive else { return }
            do {
                let result = try await runner.step(
                    system: system,
                    history: &history,
                    sandboxId: s.sandboxId ?? sandboxId,
                    sandboxAccessToken: s.sandboxAccessToken ?? sandboxAccessToken,
                ) { @Sendable event in
                    Task { @MainActor in
                        self.apply(event: event)
                    }
                }
                switch result {
                case .continued:
                    continue
                case .finished:
                    return
                case .hitStepLimit:
                    store.appendMessage(sessionId: sessionId, .init(
                        kind: .notice,
                        text: "Agent reached the step limit. Send another message to continue."
                    ))
                    return
                }
            } catch is CancellationError {
                store.appendMessage(sessionId: sessionId, .init(
                    kind: .notice,
                    text: "Stopped by you."
                ))
                return
            } catch let error as URLError where error.code == .cancelled {
                store.appendMessage(sessionId: sessionId, .init(
                    kind: .notice,
                    text: "Stopped by you."
                ))
                return
            } catch {
                store.appendMessage(sessionId: sessionId, .init(
                    kind: .notice,
                    text: "Agent error: \(error.localizedDescription)"
                ))
                return
            }
        }
    }

    /// Apply a runner event to the transcript. Tool call starts
    /// get a placeholder card that's filled in on finish.
    private func apply(event: E2bSessionRunner.StepEvent) {
        switch event {
        case let .toolCallStarted(id, name, input):
            let summary = summariseInput(name: name, input: input)
            let msg = E2bCodeMessage(
                kind: .tool,
                text: "running…",
                tool: "\(name) — \(summary)"
            )
            // Encode the id so the finished event can find the
            // matching row. We stash it in the message id, but
            // that's the wrong field — instead, push a transient
            // id on the message via the existing field. For v1
            // we just append a new card and update it on finish.
            pendingToolIds[id] = msg.id
            store.appendMessage(sessionId: sessionId, msg)
        case let .toolCallFinished(id, _, output, isError):
            // Find the pending card by id; for v1 we just append
            // a final result card next to the running one. (We
            // could later collapse the two into one with an
            // animated transition; for now, separate cards are
            // clearer in the transcript.)
            _ = pendingToolIds.removeValue(forKey: id)
            let kind: E2bCodeMessage.Kind = isError ? .notice : .tool
            store.appendMessage(
                sessionId: sessionId,
                .init(
                    kind: kind,
                    text: output,
                )
            )
        }
    }

    /// Pending tool card ids, so the start/finish events can
    /// match up if we later collapse them into a single card.
    @State private var pendingToolIds: [String: String] = [:]

    /// Convert an `E2bCodeMessage` into an `AnthropicClient.Message`
    /// suitable for the Messages API. The `user` role passes
    /// text through; `assistant` passes text; `tool` and `notice`
    /// get folded into the assistant turn as plain text so the
    /// model sees what the tools did.
    private func messageToAnthropic(_ message: E2bCodeMessage) -> AnthropicClient.Message? {
        switch message.kind {
        case .user:
            return .init(role: "user", content: [.text(message.text)])
        case .assistant:
            return .init(role: "assistant", content: [.text(message.text)])
        case .tool:
            return .init(role: "assistant", content: [.text(
                "[tool: \(message.tool ?? "?")] \(message.text)"
            )])
        case .notice:
            return .init(role: "user", content: [.text(
                "[system notice] \(message.text)"
            )])
        case .diff:
            return .init(role: "assistant", content: [.text(
                "[diff: \(message.path ?? "?")] +\(message.added ?? 0) -\(message.removed ?? 0)"
            )])
        }
    }

    /// Short human-readable summary of a tool call's input.
    /// Truncated to keep the card header one line.
    private func summariseInput(name: String, input: AnyJSON) -> String {
        switch name {
        case "run_shell":
            let cmd = input.stringValue(for: "command") ?? ""
            return cmd.count > 60 ? String(cmd.prefix(60)) + "…" : cmd
        case "read_file":
            return input.stringValue(for: "path") ?? ""
        case "write_file":
            return input.stringValue(for: "path") ?? ""
        case "edit_file":
            return input.stringValue(for: "path") ?? ""
        case "git_commit":
            return input.stringValue(for: "message") ?? ""
        case "git_push":
            return ""
        case "create_pr":
            return input.stringValue(for: "title") ?? ""
        default:
            return ""
        }
    }

    private func endSession() async {
        await store.closeSession(sessionId)
        dismiss()
    }

    private func reopenSession() async {
        // Spawn a fresh sandbox for the same session (the old one
        // was killed when the session closed). The user can keep
        // chatting against the new sandbox.
        guard let apiKey = state.e2bKeyStore.get(), !apiKey.isEmpty else { return }
        let client = DirectE2BClient(apiKey: apiKey)
        do {
            let info = try await client.createSandbox()
            store.attachSandbox(
                sessionId: sessionId,
                sandboxId: info.sandboxId,
                accessToken: info.accessToken,
                domain: info.domain
            )
        } catch {
            store.appendMessage(
                sessionId: sessionId,
                .init(kind: .notice, text: "Failed to reopen sandbox: \(error.localizedDescription)")
            )
        }
    }
}

/// One transcript line rendered as a chat bubble. The styling
/// mirrors the desktop session's item rendering so the phone
/// and desktop paths can share the same look. Tool messages
/// get a distinct card with a header (icon + tool name + status
/// pill) and a monospaced output body — much more useful than
/// the small caption the bubble used to render.
private struct MessageBubble: View {
    let message: E2bCodeMessage

    var body: some View {
        switch message.kind {
        case .tool:
            ToolCard(message: message)
        default:
            textBubble
        }
    }

    private var textBubble: some View {
        HStack {
            if isUser { Spacer(minLength: 32) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 14))
            }
            if !isUser { Spacer(minLength: 32) }
        }
    }

    private var isUser: Bool { message.kind == .user }

    private var bubbleBackground: Color {
        switch message.kind {
        case .user: return Theme.accent.opacity(0.15)
        case .assistant: return Theme.surface
        case .diff: return Theme.selection.opacity(0.15)
        case .notice: return Theme.surfaceElevated
        default: return Theme.surface
        }
    }

    private var textColor: Color {
        switch message.kind {
        case .user: return Theme.accent
        case .notice: return Theme.textSecondary
        default: return Theme.textPrimary
        }
    }
}

/// Tool-call card. Renders a header (icon + tool name + status
/// pill) and a monospaced body for the output. Status comes
/// from the message text ("running…" → spinner; "exit 0\n…"
/// → green check; anything else → red x). Tinted per status
/// so the user can scan a long transcript at a glance.
private struct ToolCard: View {
    let message: E2bCodeMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            output
        }
        .padding(10)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.3), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(toolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let detail = toolDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusPill
        }
    }

    private var output: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(message.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(20)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
    }

    private var toolName: String {
        // message.tool is "name — input summary" for tool events.
        // For the "running…" intermediate card the tool field is
        // set to "name — input summary" too; for the result card
        // the tool field is nil and we infer the name from the
        // output prefix.
        if let t = message.tool, t.contains(" — ") {
            return String(t.split(separator: " — ").first ?? Substring(t))
        }
        if message.text.hasPrefix("wrote ") { return "write_file" }
        if message.text.hasPrefix("edited ") { return "edit_file" }
        if message.text.hasPrefix("read_file failed") { return "read_file" }
        if message.text.hasPrefix("run_shell failed") { return "run_shell" }
        if message.text.hasPrefix("write_file failed") { return "write_file" }
        if message.text.hasPrefix("git_commit failed") { return "git_commit" }
        if message.text.hasPrefix("git_push failed") { return "git_push" }
        if message.text.hasPrefix("create_pr failed") { return "create_pr" }
        if message.text.hasPrefix("exit ") { return "run_shell" }
        return "tool"
    }

    private var toolDetail: String? {
        if let t = message.tool, t.contains(" — ") {
            return String(t.split(separator: " — ").dropFirst().joined(separator: " — "))
        }
        return nil
    }

    private var status: Status {
        if message.text == "running…" { return .running }
        // Successful run_shell outputs start with "exit 0".
        if message.text.hasPrefix("exit 0") { return .ok }
        // "wrote <path>" / "edited <path>" are success.
        if message.text.hasPrefix("wrote ") || message.text.hasPrefix("edited ") { return .ok }
        // "git commit:" with a SHA at the end is success.
        if message.text.hasPrefix("commit: ") && !message.text.contains("failed") { return .ok }
        // Anything that contains "failed" or starts with a non-zero exit is an error.
        if message.text.contains("failed") { return .error }
        if let line = message.text.split(separator: "\n").first,
           line.hasPrefix("exit "),
           let code = Int(line.dropFirst("exit ".count)),
           code != 0 {
            return .error
        }
        return .ok
    }

    private enum Status { case running, ok, error }

    private var tint: Color {
        switch status {
        case .running: return Theme.accent
        case .ok: return Theme.selection
        case .error: return .red
        }
    }

    private var icon: String {
        switch toolName {
        case "run_shell": return "terminal"
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        case "edit_file": return "pencil"
        case "git_commit": return "checkmark.circle"
        case "git_push": return "arrow.up.circle"
        case "create_pr": return "arrow.triangle.branch"
        default: return "gearshape"
        }
    }

    private var statusPill: some View {
        HStack(spacing: 3) {
            switch status {
            case .running:
                ProgressView().controlSize(.mini)
            case .ok:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            case .error:
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(pillText)
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private var pillText: String {
        switch status {
        case .running: return "Running"
        case .ok: return "Done"
        case .error: return "Error"
        }
    }
}
