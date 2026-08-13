import SwiftUI
import AnyProvCore

/// Inline "Saved to memory" card shown beneath the assistant message that
/// triggered an auto-save. Reads the corresponding `ActivityEntry` from
/// `UserMemoryStore` so the label and preview stay in sync if the user
/// edits the entry later. Tapping Undo calls `UserMemoryStore.undoActivity`
/// and dismisses the card.
struct MemoryHintCard: View {
    @ObservedObject var memory: UserMemoryStore
    let activityID: String
    var onUndo: (() -> Void)?

    var body: some View {
        if let row = memory.activityList().first(where: { $0.id == activityID }) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon(for: row.kind))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label(for: row))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !row.detailPreview.isEmpty {
                        Text(row.detailPreview)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                Button {
                    _ = memory.undoActivity(id: activityID)
                    onUndo?()
                } label: {
                    Text("Undo")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.separator, lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label(for: row)) — \(row.detailPreview). Tap Undo to remove.")
            .accessibilityAction(named: "Undo") {
                _ = memory.undoActivity(id: activityID)
                onUndo?()
            }
        }
    }

    private func label(for row: UserMemoryStore.ActivityEntry) -> String {
        switch row.kind {
        case .add: return "Saved to memory"
        case .update: return "Updated memory"
        case .forget: return "Forgot from memory"
        case .rename: return "Renamed memory"
        }
    }

    private func icon(for kind: UserMemoryStore.ActivityEntry.Kind) -> String {
        switch kind {
        case .add: return "checkmark.circle.fill"
        case .update: return "pencil.circle"
        case .forget: return "minus.circle"
        case .rename: return "tag"
        }
    }
}
