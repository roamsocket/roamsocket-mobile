import SwiftUI

/// Renders an individual chat message with actions
struct ChatMessageView: View {
    let message: ChatMessage
    var onCopy: () -> Void
    var onShare: () -> Void
    var onStar: () -> Void
    var onDelete: () -> Void
    var onRegenerate: () -> Void
    var onThoughtProcess: () -> Void
    
    @State private var showActions = false
    
    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            // Thought process indicator
            if message.thoughtProcess != nil && message.role == .assistant {
                Button(action: onThoughtProcess) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 14))
                        Text("Thought process")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            
            // Message content
            if message.role == .user {
                userMessageBubble
            } else {
                assistantMessageContent
            }
            
            // Message actions (for assistant messages)
            if message.role == .assistant && !message.isStreaming {
                messageActions
            }
        }
        .confirmationDialog("Message Actions", isPresented: $showActions, titleVisibility: .visible) {
            Button("Copy", action: onCopy)
            Button("Share", action: onShare)
            Button("Star", action: onStar)
            Button("Regenerate", action: onRegenerate)
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
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
            // Step indicator
            if message.toolCalls != nil && !message.toolCalls!.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14))
                    Text("\(message.toolCalls!.count) steps")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            
            // Content
            Text(message.content)
                .font(.system(size: 17))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            
            // Streaming indicator
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
            actionButton(systemImage: "play.fill", action: {})
            actionButton(systemImage: "hand.thumbsup", action: {})
            actionButton(systemImage: "hand.thumbsdown", action: {})
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
                content: "I don't game"
            ),
            onCopy: {},
            onShare: {},
            onStar: {},
            onDelete: {},
            onRegenerate: {},
            onThoughtProcess: {}
        )
        
        ChatMessageView(
            message: ChatMessage(
                role: .assistant,
                content: "Fixed — here's the updated blurb without gaming:\n\nColorado based, building a nonprofit app around everyday kindness, and probably outside hiking or exploring when I'm not working on it. I'm looking for something real and long term, but I've always believed the good ones start as friendships first. No rush, just genuinely getting to know someone and seeing where it goes. If you've got a favorite trail, a good book recommendation, or a story that starts with \"so this one time,\" I'm listening.",
                thoughtProcess: "They've confirmed this is for a Plenty of Fish dating profile. I should ask a few targeted questions to help write an effective blurb without overwhelming them with too many prompts."
            ),
            onCopy: {},
            onShare: {},
            onStar: {},
            onDelete: {},
            onRegenerate: {},
            onThoughtProcess: {}
        )
    }
    .padding()
    .background(Theme.background)
}
