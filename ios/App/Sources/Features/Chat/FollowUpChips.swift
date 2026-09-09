import SwiftUI

/// Horizontal row of follow-up suggestion chips. Renders below
/// the assistant bubble in the chat composer or in the E2B
/// session's input area. Tapping a chip hands the label back
/// to the parent for the next user turn.
struct FollowUpChips: View {
    /// Ordered list of chip labels. Empty array renders nothing.
    let suggestions: [String]
    /// Tap callback — receives the label the user picked.
    var onPick: (String) -> Void

    var body: some View {
        if suggestions.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, label in
                        Button {
                            onPick(label)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                Text(label)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.surface, in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Theme.separator.opacity(0.7), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Send: \(label)")
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 16) {
        FollowUpChips(
            suggestions: ["Show me the diff", "Bump the TTL", "Add a unit test"],
            onPick: { _ in }
        )
        FollowUpChips(
            suggestions: ["Try the smaller API", "Add retry logic", "Switch to streaming"],
            onPick: { _ in }
        )
    }
    .padding()
    .background(Theme.background)
}
#endif
