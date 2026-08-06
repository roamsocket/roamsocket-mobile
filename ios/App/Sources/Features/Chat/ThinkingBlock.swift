import SwiftUI
import UIKit

/// Collapsed-by-default grey disclosure for model reasoning (`<think>` body).
/// Used in both chat and coding-session transcripts.
/// Press-and-hold copies the full thinking text to the clipboard.
struct ThinkingBlock: View {
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
