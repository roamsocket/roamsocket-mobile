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

    /// Prefer an explicit `thoughtProcess`; otherwise peel `<think>` tags
    /// out of the visible content so raw markup never shows in the bubble.
    private var resolvedThinking: (text: String?, content: String) {
        if let existing = message.thoughtProcess, !existing.isEmpty {
            // Content may still contain tags if it was set independently.
            let parsed = ThinkingExtractor.extract(from: message.content)
            return (existing, parsed.content.isEmpty ? message.content : parsed.content)
        }
        let parsed = ThinkingExtractor.extract(from: message.content)
        return (parsed.thinking, parsed.content)
    }

    private var assistantMessageContent: some View {
        let resolved = resolvedThinking
        return VStack(alignment: .leading, spacing: 12) {
            if let thinking = resolved.text, !thinking.isEmpty {
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

            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                actionChipsRow(toolCalls: toolCalls)
            }

            if !resolved.content.isEmpty {
                Text(resolved.content)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

/// Collapsed-by-default grey disclosure for model reasoning (`<think>` body).
/// Press-and-hold copies the full thinking text to the clipboard.
private struct ThinkingBlock: View {
    let text: String
    let expanded: Bool
    var onToggle: () -> Void

    @State private var showCopiedToast = false

    private var firstLine: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14, height: 14)

                Text("Thinking")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(0.2)

                if !expanded {
                    Text(firstLine)
                        .font(.system(size: 13).italic())
                        .foregroundStyle(Theme.textTertiary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }

                Spacer(minLength: 0)

                if showCopiedToast {
                    Text("Copied")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(expanded ? "Collapse thinking" : "Expand thinking")
            .accessibilityHint("Shows the model’s private reasoning. Press and hold to copy.")
            .accessibilityAction(named: "Copy thinking") { copyThinking() }

            if expanded {
                Text(text)
                    .font(.system(size: 13.5).italic())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .transition(
                        .asymmetric(
                            insertion: .opacity
                                .combined(with: .move(edge: .top))
                                .combined(with: .scale(scale: 0.98, anchor: .top)),
                            removal: .opacity
                                .combined(with: .move(edge: .top))
                        )
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Long-press anywhere on the block copies thinking (tap still toggles).
        .onLongPressGesture(minimumDuration: 0.4, perform: copyThinking)
        .contextMenu {
            Button {
                copyThinking()
            } label: {
                Label("Copy thinking", systemImage: "doc.on.doc")
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: expanded)
        .animation(.easeOut(duration: 0.18), value: showCopiedToast)
    }

    private func copyThinking() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = trimmed
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        withAnimation(.easeOut(duration: 0.15)) {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.2)) {
                showCopiedToast = false
            }
        }
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
