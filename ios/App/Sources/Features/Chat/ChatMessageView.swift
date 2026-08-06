import SwiftUI

/// Renders an individual chat message with actions.
struct ChatMessageView: View {
    @EnvironmentObject var state: AppState
    let message: ChatMessage
    var onCopy: () -> Void
    var onShare: () -> Void
    var onDelete: () -> Void
    var onRegenerate: () -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            if message.role == .user {
                userMessageBubble
            } else {
                assistantMessageContent
            }

            if message.role == .assistant && !message.isStreaming {
                messageActions
            }
        }
    }

    // MARK: - User Message

    private var userMessageBubble: some View {
        Text(message.content)
            .font(.system(size: 17))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 20))
            // Stretch to the right edge with a tiny margin so it doesn't float.
            // Cap width to keep longer messages readable.
            .frame(maxWidth: 320, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Assistant Message

    /// Prefer an explicit `thoughtProcess`; otherwise peel `<think>` tags
    /// out of the visible content so raw markup never shows in the bubble.
    /// Empty `text` (non-nil) means tags were present with no body yet → grey Thinking...
    private var resolvedThinking: (text: String?, content: String) {
        if let existing = message.thoughtProcess, !existing.isEmpty {
            // Content may still contain tags if it was set independently.
            let parsed = ThinkingExtractor.extract(from: message.content)
            let visible = parsed.content
            // Keep stored reasoning; never fall back to raw tagged content.
            return (existing, visible)
        }
        let parsed = ThinkingExtractor.extract(from: message.content)
        return (parsed.thinking, parsed.content)
    }

    private var assistantMessageContent: some View {
        let resolved = resolvedThinking
        return VStack(alignment: .leading, spacing: 12) {
            // Non-nil thinking (including empty body) → clock + grey summary row.
            if let thinking = resolved.text {
                ThinkingBlock(
                    text: thinking,
                    summary: message.thoughtSummary,
                    expanded: state.alwaysExpandThinking
                )
            }

            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                toolStatusLines(toolCalls: toolCalls)
            }

            if !resolved.content.isEmpty {
                MarkdownContentView(text: resolved.content, fontSize: 17)
            }

            // Show dots only while waiting on the model after tools finish
            // (or when there are no tool lines yet).
            if message.isStreaming, resolved.content.isEmpty {
                let toolsBusy = message.toolCalls?.contains {
                    if case .running = $0.status { return true }
                    if case .pending = $0.status { return true }
                    return false
                } ?? false
                if !toolsBusy {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(Theme.textSecondary)
                                .frame(width: 6, height: 6)
                                .opacity(0.3 + Double(i) * 0.3)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Grey tool-use status lines (web search, research, Wikipedia, …).
    /// Mirrors the thinking-row treatment: tertiary text, no card chrome.
    private func toolStatusLines(toolCalls: [ToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(toolCalls) { call in
                HStack(alignment: .top, spacing: 8) {
                    Group {
                        if case .running = call.status {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: iconForTool(call))
                                .font(.system(size: 12, weight: .regular))
                        }
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(call.summary)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)

                        if let detail = call.detail,
                           !detail.isEmpty,
                           call.status == .completed || isFailed(call.status)
                        {
                            Text(detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary.opacity(0.85))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: call))
            }
        }
    }

    private func isFailed(_ status: ToolCall.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func iconForTool(_ call: ToolCall) -> String {
        if case .failed = call.status { return "exclamationmark.circle" }
        switch call.name {
        case "web_search", "research": return "globe"
        case "wikipedia": return "book"
        case "bash", "shell": return "terminal"
        case "read_file": return "doc.text"
        case "write_file", "edit_file": return "square.and.pencil"
        case "grep": return "magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }

    private func accessibilityLabel(for call: ToolCall) -> String {
        var parts = [call.summary]
        if let detail = call.detail, !detail.isEmpty {
            parts.append(detail)
        }
        switch call.status {
        case .running: parts.append("in progress")
        case .pending: parts.append("pending")
        case .failed: parts.append("failed")
        case .completed: break
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Message Actions

    private var messageActions: some View {
        HStack(spacing: 4) {
            actionButton(systemImage: "doc.on.doc", action: onCopy)
            actionButton(systemImage: "square.and.arrow.up", action: onShare)
            actionButton(systemImage: "arrow.clockwise", action: onRegenerate)
        }
        .padding(.top, 4)
    }

    private func actionButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 20) {
        ChatMessageView(
            message: ChatMessage(
                role: .user,
                content: "Hello"
            ),
            onCopy: {},
            onShare: {},
            onDelete: {},
            onRegenerate: {}
        )

        ChatMessageView(
            message: ChatMessage(
                role: .assistant,
                content: """
                <think>
                Let me think about what the user really wants here. They said hello, so I should be warm but quick.
                </think>
                Hi there — how can I help?
                """
            ),
            onCopy: {},
            onShare: {},
            onDelete: {},
            onRegenerate: {}
        )
    }
    .padding()
    .background(Theme.background)
    .environmentObject(AppState(secrets: KeychainSecretStore()))
}
