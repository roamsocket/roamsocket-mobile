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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18))
                .onSubmit(send)
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

    /// Send the current draft as a user message. The runner is
    /// wired in a follow-up commit; for now this appends a
    /// placeholder assistant reply so the UI flow is end-to-end
    /// testable before the LLM integration lands.
    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session?.isLive == true else { return }
        let userMessage = E2bCodeMessage(kind: .user, text: trimmed)
        store.appendMessage(sessionId: sessionId, userMessage)
        draft = ""
        isSending = true
        Task { @MainActor in
            // Placeholder reply — replaced by the E2bSessionRunner
            // in the agent-loop commit. Lives long enough to
            // exercise the send / append / scroll UX.
            try? await Task.sleep(nanoseconds: 800_000_000)
            store.appendMessage(
                sessionId: sessionId,
                .init(
                    kind: .notice,
                    text: "Agent loop not wired yet — the LLM runner ships in the next commit."
                )
            )
            isSending = false
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
/// and desktop paths can share the same look.
private struct MessageBubble: View {
    let message: E2bCodeMessage

    var body: some View {
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
                if let tool = message.tool {
                    Text(tool)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                }
            }
            if !isUser { Spacer(minLength: 32) }
        }
    }

    private var isUser: Bool { message.kind == .user }

    private var bubbleBackground: Color {
        switch message.kind {
        case .user: return Theme.accent.opacity(0.15)
        case .assistant: return Theme.surface
        case .tool: return Theme.surfaceElevated
        case .diff: return Theme.selection.opacity(0.15)
        case .notice: return Theme.surfaceElevated
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
