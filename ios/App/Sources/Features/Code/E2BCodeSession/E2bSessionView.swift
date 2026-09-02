import SwiftUI
import AnyProvCore

/// Chat-style UI for an E2B code session. The user types a
/// message at the bottom; the agent loop (driven by
/// `E2bSessionRunner`) streams the model's text into the
/// transcript and dispatches tool calls against the live e2b
/// sandbox. The runner picks the right `AgentLLM` based on the
/// user's selected provider (Anthropic, OpenAI, Groq, OpenRouter,
/// xAI, Mistral, custom OpenAI-compatible endpoints).
///
/// The session is identified by its `E2bCodeSession.id` so the
/// view reuses the store's session instance across renders.
/// Closing the view (sheet dismiss, back button) does *not* kill
/// the sandbox — the user can return to the same session from
/// the Code home. An explicit "End session" button in the toolbar
/// calls `closeSession` on the store.
struct E2bSessionView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let sessionId: UUID
    /// Owned by the parent (the Code home). The view mutates
    /// transcript messages via the store, never directly.
    @ObservedObject var store: E2bSessionStore

    @State private var draft: String = ""
    @State private var isSending: Bool = false
    /// Local-only buffer for the currently-streaming assistant
    /// message. While non-empty we render a bubble after the
    /// regular transcript so the user sees the model typing.
    /// When the stream finishes we flush it to the store as a
    /// normal `assistant` message and clear the buffer.
    @State private var streamingText: String = ""
    @State private var agentTask: Task<Void, Never>?
    /// Drives the model picker sheet. Surfaced as a small pill
    /// above the input bar so the user can change models without
    /// leaving the code session — the picker is filtered to
    /// coding-capable providers via `codingOnly: true`.
    @State private var showModelPicker: Bool = false
    @State private var showProviderSettings: Bool = false
    @FocusState private var inputFocused: Bool
    @Environment(\.openURL) private var openURL

    private var session: E2bCodeSession? { store.session(id: sessionId) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    statusBar
                    messagesList
                    costFooter
                    inputBar
                }
            }
            .navigationTitle(session?.title ?? "Session")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showModelPicker, onDismiss: syncSessionModelFromGlobal) {
                ModelPickerSheet(codingOnly: true)
                    .environmentObject(state)
            }
            .sheet(isPresented: $showProviderSettings) {
                // The "Add a model" CTA in the model pill needs
                // somewhere to land. The chat composer's
                // `showProviderSettings` jumps into the providers
                // tab; here we re-use the same view but inside the
                // session sheet so the back button still returns to
                // the chat.
                AppSettingsView()
                    .environmentObject(state)
            }
            .toolbar {
                // Leave the chat without killing the sandbox — the
                // session stays listed on the Code home and can be
                // reopened later. "End session" (in the trailing
                // menu) is the only action that tears the sandbox
                // down, so the back button is the cheap escape.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        inputFocused = false
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
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
                    if let url = s.sandboxUrl, let parsed = URL(string: url) {
                        Button {
                            openURL(parsed)
                        } label: {
                            Image(systemName: "safari")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open sandbox in browser")
                    }
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
                    // Streaming assistant message: ephemeral,
                    // shows the model typing in real time. Disappears
                    // once the turn's .streamFinished flushes it
                    // into the transcript as a regular message.
                    if !streamingText.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(streamingText)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                        .id("streaming-anchor")
                    }
                    if isSending && streamingText.isEmpty {
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
                if isSending {
                    proxy.scrollTo("sending-anchor", anchor: .bottom)
                } else if let last = session?.transcript.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: streamingText) { _, _ in
                // Auto-scroll as the model types so the user
                // sees the latest text without having to drag.
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("streaming-anchor", anchor: .bottom)
                }
            }
        }
    }

    /// Thin footer showing the running token total + estimated
    /// USD cost. Hidden when both counters are zero.
    private var costFooter: some View {
        Group {
            if let s = session, s.totalInputTokens + s.totalOutputTokens > 0 {
                let rate = TokenCost.pricingFor(modelID: s.modelID)
                let total = TokenCost.costUSD(
                    inputTokens: s.totalInputTokens,
                    outputTokens: s.totalOutputTokens,
                    rate: rate
                )
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text("\(s.totalInputTokens) in · \(s.totalOutputTokens) out")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text(TokenCost.formatUSD(total))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Theme.surface)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.separator)
            // Model picker — sits above the text field so the
            // user can see which model is about to run and
            // switch without leaving the session. The pill's
            // `requiresCodingAgent` flag means phone-only Metal
            // isn't offered (the agent loop is wired for
            // Anthropic / OpenAI-compatible providers).
            HStack(spacing: 8) {
                ModelSelectorPill(
                    modelDisplayName: modelPillTitle,
                    onPick: {
                        inputFocused = false
                        showModelPicker = true
                    },
                    onAddModel: {
                        inputFocused = false
                        showProviderSettings = true
                    },
                    requiresCodingAgent: true
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
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

    /// Display name shown on the model pill above the input
    /// bar. Empty when no model is selected — the pill itself
    /// switches into the "+ Add a model" CTA in that case.
    /// The session has its own `modelID` (stamped at first turn
    /// so cost estimates stay consistent), but the picker
    /// writes through `state.selectedModel` and mirrors onto
    /// the session — that's what `send()` already reads, so
    /// changing the pill takes effect on the next message.
    private var modelPillTitle: String {
        guard let model = state.selectedModel else { return "" }
        return state.displayName(for: model)
    }

    /// Mirror the global `state.selectedModel` onto the session
    /// when the model picker dismisses. Without this, the cost
    /// footer would keep quoting the old rate until the next
    /// message goes out (and `send()` only stamps the session
    /// when the model *id* changes, so a same-id rename via
    /// the picker would be invisible). Cheap to call — the
    /// store's setter is a no-op when the value is unchanged.
    private func syncSessionModelFromGlobal() {
        guard let model = state.selectedModel,
              let s = session,
              s.modelID != model.modelID
        else { return }
        store.setModelID(sessionId, modelID: model.modelID)
    }

    // MARK: - Actions

    /// Send the current draft as a user message. Drives the
    /// agent loop via `E2bSessionRunner` until the model ends
    /// the turn or we hit the step limit. The runner picks the
    /// right `AgentLLM` based on the user's selected model +
    /// provider, so this works for Anthropic, OpenAI, Groq,
    /// OpenRouter, xAI, Mistral, and any custom OpenAI-compatible
    /// endpoint the user has added.
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

        guard let model = state.selectedModel else {
            store.appendMessage(sessionId: sessionId, .init(
                kind: .notice,
                text: "Pick a model on the home screen first."
            ))
            isSending = false
            return
        }
        let apiKey = state.resolvedAPIKey(for: model.provider)
        guard !apiKey.isEmpty else {
            store.appendMessage(sessionId: sessionId, .init(
                kind: .notice,
                text: "Add an API key for \(model.provider.displayName) in Settings → Providers first."
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

        // Stamp the model id onto the session so the cost
        // estimate stays consistent even if the user later changes
        // the selected model in Settings.
        if s.modelID != model.modelID {
            store.setModelID(sessionId, modelID: model.modelID)
        }

        let system = E2bSessionRunner.systemPrompt(
            repoFullName: s.repoFullName,
            branch: s.branch
        )
        // Build the right AgentLLM for the user's provider. The
        // base URL + model name come from the selected model +
        // provider. The factory hides the Anthropic vs OpenAI
        // split from the runner.
        let agentLLM: AgentLLM
        do {
            // The factory picks the right default base URL for
            // built-in providers (OpenAI, Groq, etc.); pass `nil`
            // so the factory owns the URL choice. Custom providers
            // need their own URL stored on `model` — fall back to
            // nil here and the user can re-add the key if needed.
            let baseURL: URL? = nil
            agentLLM = try AgentLLMFactory.make(
                provider: model.provider,
                modelID: model.modelID,
                apiKey: apiKey,
                baseURL: baseURL
            )
        } catch {
            store.appendMessage(sessionId: sessionId, .init(
                kind: .notice,
                text: "Couldn't build LLM client: \(error.localizedDescription)"
            ))
            isSending = false
            return
        }

        agentTask?.cancel()
        agentTask = Task { @MainActor in
            await runAgentLoop(
                system: system,
                sandboxId: sandboxId,
                sandboxAccessToken: sandboxAccessToken,
                e2bKey: e2bKey,
                anthropicApiKey: apiKey,  // legacy: ignored for non-Anthropic
                modelName: model.modelID,
                agentLLM: agentLLM,
                github: GitHubContext(
                    token: state.githubToken,
                    repoFullName: s.repoFullName,
                    branch: s.branch
                )
            )
            self.agentTask = nil
        }
    }

    /// The agent loop. Builds the runner, replays the session
    /// transcript into a `messages` array, then steps until the
    /// model ends the turn or the step limit is hit. Each step
    /// surfaces its tool calls as transcript cards and the
    /// assistant's text as a normal message.
    private func runAgentLoop(
        system: String,
        sandboxId: String,
        sandboxAccessToken: String?,
        e2bKey: String,
        anthropicApiKey: String,
        modelName: String,
        agentLLM: AgentLLM,
        github: GitHubContext,
    ) async {
        // Flip the session status to .working so the Code home
        // shows the right pill on this row. Restore to .idle at
        // the bottom of the function.
        store.setStatus(sessionId, .working)
        defer {
            isSending = false
            store.setStatus(sessionId, .idle)
        }
        // Pull the current transcript into a common message
        // array (provider-agnostic) for the AgentLLM to consume.
        var history: [AgentLLMMessage] = []
        if let s = store.session(id: sessionId) {
            history = s.transcript.compactMap(messageToAgent)
        }
        let e2b = DirectE2BClient(apiKey: e2bKey)
        let runner = E2bSessionRunner(e2b: e2b, agentLLM: agentLLM, github: github)

        while !Task.isCancelled {
            guard let s = store.session(id: sessionId), s.isLive else { return }
            // Keep-alive: e2b sandboxes expire 1 hour after creation
            // (or the last timeout reset). Reset the clock on every
            // step — this is the `setTimeout(...)` per user_message /
            // tool_call the E2B design doc prescribes. Best effort:
            // a failed extension shouldn't fail the turn.
            try? await e2b.extendTimeout(sandboxId: s.sandboxId ?? sandboxId)
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
                case .continued: continue
                case .finished: return
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
            _ = modelName  // unused after refactor; kept for debugging
            _ = anthropicApiKey
        }
    }

    /// Apply a runner event to the transcript. Tool call starts
    /// get a placeholder card that's filled in on finish. Usage
    /// events are routed to the store. Stream events drive the
    /// local `streamingText` buffer and commit to the store when
    /// the model finishes.
    private func apply(event: E2bSessionRunner.StepEvent) {
        switch event {
        case let .toolCallStarted(id, name, input):
            let summary = summariseInput(name: name, input: input)
            let msg = E2bCodeMessage(
                kind: .tool,
                text: "running…",
                tool: "\(name) — \(summary)"
            )
            store.appendMessage(sessionId: sessionId, msg)
        case let .toolCallFinished(id, _, output, isError):
            let kind: E2bCodeMessage.Kind = isError ? .notice : .tool
            store.appendMessage(
                sessionId: sessionId,
                .init(kind: kind, text: output)
            )
        case let .usageRecorded(inputTokens, outputTokens):
            store.recordUsage(
                sessionId: sessionId,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
            )
        case .streamStarted:
            streamingText = ""
        case let .textDelta(text):
            streamingText.append(text)
        case let .streamFinished(text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.appendMessage(
                    sessionId: sessionId,
                    .init(kind: .assistant, text: text)
                )
            }
            streamingText = ""
        }
    }

    /// Convert an `E2bCodeMessage` to the provider-agnostic
    /// `AgentLLMMessage` the runner consumes. Tools + notices are
    /// folded into the assistant turn as plain text so the model
    /// sees what happened.
    private func messageToAgent(_ message: E2bCodeMessage) -> AgentLLMMessage? {
        switch message.kind {
        case .user:
            return .init(role: .user, content: message.text)
        case .assistant:
            return .init(role: .assistant, content: message.text)
        case .tool:
            return .init(role: .assistant, content: "[tool: \(message.tool ?? "?")] \(message.text)")
        case .notice:
            return .init(role: .user, content: "[system notice] \(message.text)")
        case .diff:
            return .init(role: .assistant, content: "[diff: \(message.path ?? "?")] +\(message.added ?? 0) -\(message.removed ?? 0)")
        }
    }

    /// Short human-readable summary of a tool call's input.
    private func summariseInput(name: String, input: AgentLLMInput) -> String {
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

// MARK: - Message bubble

/// One transcript line rendered as a chat bubble. Tool messages
/// get a distinct card with a header (icon + tool name + status
/// pill) and a monospaced output body.
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

// MARK: - Tool card

/// Tool-call card. Header (icon + tool name + status pill) +
/// monospaced body. For `edit_file` results the body is rendered
/// with colour-tinted diff lines (green `+`, red `-`).
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

    @ViewBuilder
    private var output: some View {
        let body = message.text
        if isDiffBody(body) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines(body).enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 240)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body)
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
    }

    private var toolName: String {
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
        if message.text.hasPrefix("exit 0") { return .ok }
        if message.text.hasPrefix("wrote ") || message.text.hasPrefix("edited ") { return .ok }
        if message.text.hasPrefix("commit: ") && !message.text.contains("failed") { return .ok }
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

    private func isDiffBody(_ body: String) -> Bool {
        guard let first = body.split(separator: "\n").first,
              first.hasPrefix("@@") else { return false }
        return body.contains("\n+") || body.contains("\n-")
    }

    private struct DiffLine { let text: String; let color: Color }

    private func diffLines(_ body: String) -> [DiffLine] {
        body.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let s = String(raw)
            if s.hasPrefix("@@") { return DiffLine(text: s, color: Theme.accent) }
            if s.hasPrefix("+") { return DiffLine(text: s, color: Theme.selection) }
            if s.hasPrefix("-") { return DiffLine(text: s, color: .red) }
            return DiffLine(text: s, color: Theme.textSecondary)
        }
    }
}
