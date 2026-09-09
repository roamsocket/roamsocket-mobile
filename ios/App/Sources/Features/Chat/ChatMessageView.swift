import SwiftUI
import UIKit

/// Renders an individual chat message with actions.
struct ChatMessageView: View {
    @EnvironmentObject var state: AppState
    let message: ChatMessage
    var onCopy: () -> Void
    var onShare: () -> Void
    var onDelete: () -> Void
    var onRegenerate: () -> Void
    /// Tap a follow-up suggestion chip → parent seeds the composer
    /// with the label and sends the next turn.
    var onPickSuggestion: (String) -> Void = { _ in }
    /// Highlight when this message is the source of the open artifact panel.
    var isArtifactSource: Bool = false

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
        .padding(isArtifactSource ? 10 : 0)
        .background(
            isArtifactSource
                ? RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accent.opacity(0.08))
                : nil
        )
        .overlay(
            isArtifactSource
                ? RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.accent.opacity(0.45), lineWidth: 1)
                : nil
        )
    }

    // MARK: - User Message

    private var userMessageBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let imageAttachments = message.attachments?.filter({ $0.type == .image }),
               !imageAttachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(imageAttachments) { attachment in
                        if let data = attachment.thumbnailData, let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 132, height: 132)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(message.content)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 20))
                    .contentShape(RoundedRectangle(cornerRadius: 20))
                    // Enable system text selection so the user can long-press
                    // and drag to copy a portion of the message. The system
                    // edit menu also exposes a "Copy" action that copies the
                    // current selection (or the whole message after Select All).
                    .textSelection(.enabled)
            }
        }
        // Stretch to the right edge with a tiny margin so it doesn't float.
        // Cap width to keep longer messages readable.
        .frame(maxWidth: 320, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .contextMenu {
            // Context menu still offers a one-tap "Copy whole" for users who
            // don't need partial selection. Long-pressing in place shows this
            // menu; long-pressing and dragging starts a text selection.
            Button {
                let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onCopy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        .accessibilityAction(named: "Copy") {
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onCopy()
        }
    }

    // MARK: - Assistant Message

    /// Peel `<think>` tags (and friends) out of the visible content
    /// so raw markup never shows in the bubble, then peel any
    /// `[SUGGEST: a | b | c]` markers (or `<suggest>…</suggest>` /
    /// `Next steps:` numbered-list) out so the chip row can render
    /// them. Empty `thinking` text (non-nil) means tags were
    /// present with no body yet → grey Thinking...
    private var resolvedThinking: (text: String?, content: String, suggestions: [String]) {
        let raw = message.content
        let parsed: ThinkingExtractor.Result
        let storedReasoning = message.thoughtProcess
        if let existing = storedReasoning, !existing.isEmpty {
            // Content may still contain tags if it was set independently.
            parsed = ThinkingExtractor.extract(from: raw)
        } else {
            parsed = ThinkingExtractor.extract(from: raw)
        }
        // Keep stored reasoning; never fall back to raw tagged content.
        let thinking = storedReasoning?.isEmpty == false ? storedReasoning : parsed.thinking
        let followUps = FollowUpExtractor.extract(from: parsed.content)
        return (thinking, followUps.content, followUps.suggestions)
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

            // Follow-up suggestion chips below the prose. The model
            // emits these as `[SUGGEST: a | b | c]`, `<suggest>…</suggest>`,
            // or a "Next steps:" numbered list; we strip them out of
            // `resolved.content` and render the chips here so the user
            // can one-tap the next turn. Hidden while the model is still
            // streaming (we don't know yet whether the trailing marker
            // is real or a hallucinated prefix).
            if !message.isStreaming, !resolved.suggestions.isEmpty {
                FollowUpChips(suggestions: resolved.suggestions, onPick: onPickSuggestion)
                    .padding(.top, 2)
            }

            if let ids = message.memoryActivityIDs, !ids.isEmpty {
                ForEach(ids, id: \.self) { id in
                    MemoryHintCard(memory: UserMemoryStore.shared, activityID: id)
                }
            }

            // Animated typing indicator while waiting on the model after tools
            // finish (or when there are no tool lines yet). Skip when the
            // thinking row already shows its own "Thinking" + dots placeholder.
            if message.isStreaming, resolved.content.isEmpty {
                let toolsBusy = message.toolCalls?.contains {
                    if case .running = $0.status { return true }
                    if case .pending = $0.status { return true }
                    return false
                } ?? false
                let thinkingPlaceholder = resolved.text.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } ?? false
                if !toolsBusy, !thinkingPlaceholder {
                    AssistantTypingIndicator()
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
