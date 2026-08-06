import SwiftUI

/// Renders an individual chat message with actions.
struct ChatMessageView: View {
    @EnvironmentObject var state: AppState
    let message: ChatMessage
    var onCopy: () -> Void
    var onShare: () -> Void
    var onDelete: () -> Void
    var onRegenerate: () -> Void

    /// Local override so a tap on the disclosure persists across redraws.
    @State private var thinkingExpandedOverride: Bool?

    private var thinkingExpanded: Bool {
        thinkingExpandedOverride ?? state.alwaysExpandThinking
    }

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

    private var assistantMessageContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let thinking = message.thoughtProcess, !thinking.isEmpty {
                ThinkingBlock(
                    text: thinking,
                    expanded: thinkingExpanded,
                    onToggle: { thinkingExpandedOverride = !thinkingExpanded }
                )
            }

            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                actionChipsRow(toolCalls: toolCalls)
            }

            Text(message.content)
                .font(.system(size: 17))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if message.isStreaming {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact, mobile-optimized version of the tool-call stack. Each step
    /// is a pill; tapping it does nothing (a future detail sheet), long
    /// press copies the summary. Steps are horizontally scrollable so a
    /// long chain doesn't dominate the bubble.
    private func actionChipsRow(toolCalls: [ToolCall]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(toolCalls) { call in
                    HStack(spacing: 4) {
                        Image(systemName: iconForTool(call.name))
                            .font(.system(size: 10, weight: .semibold))
                        Text(call.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceElevated, in: Capsule())
                }
            }
        }
    }

    private func iconForTool(_ name: String) -> String {
        switch name {
        case "bash", "shell": return "terminal"
        case "read_file": return "doc.text"
        case "write_file", "edit_file": return "square.and.pencil"
        case "grep": return "magnifyingglass"
        default: return "circle.dotted"
        }
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

// MARK: - Thinking block

private struct ThinkingBlock: View {
    let text: String
    let expanded: Bool
    var onToggle: () -> Void

    private var firstLine: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Thinking")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 4)
                    if !expanded {
                        Text(firstLine)
                            .font(.system(size: 13).italic())
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: 14).italic())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
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
                content: "Hi there — how can I help?",
                thoughtProcess: "Let me think about what the user really wants here. They said hello, so I should be warm but quick."
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
