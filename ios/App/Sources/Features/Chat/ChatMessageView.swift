import SwiftUI

/// Renders an individual chat message with actions.
struct ChatMessageView: View {
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
            .frame(maxWidth: 280, alignment: .trailing)
    }

    // MARK: - Assistant Message

    private var assistantMessageContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14))
                    Text("\(toolCalls.count) steps")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Theme.textSecondary)
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
            message: ChatMessage(role: .user, content: "Hello"),
            onCopy: {},
            onShare: {},
            onDelete: {},
            onRegenerate: {}
        )

        ChatMessageView(
            message: ChatMessage(role: .assistant, content: "Hi there — how can I help?"),
            onCopy: {},
            onShare: {},
            onDelete: {},
            onRegenerate: {}
        )
    }
    .padding()
    .background(Theme.background)
}
