import SwiftUI

/// Save state shown on a flashcard's Save button.
enum StudyCardSaveState: Equatable {
    /// Never written to the deck yet.
    case unsaved
    /// Saved and unchanged since.
    case saved
    /// Already saved but edited again since the last save.
    case dirty
}

/// One editable flashcard card: Question / Answer / Reasoning fields plus a
/// per-card Save button. Shared by the scan review flow and deck detail.
struct StudyFlashcardCardView: View {
    let index: Int
    @Binding var question: String
    @Binding var answer: String
    @Binding var reasoning: String
    var saveState: StudyCardSaveState
    /// Hide the per-card Save button (deck detail auto-saves on edit).
    var showsSaveButton: Bool = true
    var onEdit: () -> Void = {}
    var onSave: () -> Void = {}
    /// When non-nil, shows a trash button next to the save button.
    var onDelete: (() -> Void)? = nil

    @FocusState private var focusedField: Field?

    private enum Field {
        case question, answer, reasoning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            field(
                label: "Question",
                placeholder: "Type the question…",
                systemImage: "questionmark.circle",
                text: $question,
                field: .question
            )

            field(
                label: "Answer",
                placeholder: "Type the answer…",
                systemImage: "checkmark.circle",
                text: $answer,
                field: .answer
            )

            field(
                label: "Reason",
                placeholder: "Why is this correct?…",
                systemImage: "lightbulb.circle",
                text: $reasoning,
                field: .reasoning
            )
        }
        .padding(16)
        .background(
            Theme.surface,
            in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(
                    saveState == .unsaved
                        ? Theme.accent.opacity(0.4)
                        : Theme.separator.opacity(0.7),
                    lineWidth: saveState == .unsaved ? 1.5 : 1
                )
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Question \(index)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            if showsSaveButton {
                saveButton
            }
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete question \(index)")
            }
        }
    }

    private var saveButton: some View {
        Button(action: onSave) {
            HStack(spacing: 5) {
                Image(systemName: saveStateIcon)
                    .font(.system(size: 12, weight: .semibold))
                Text(saveStateLabel)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(saveState == .saved ? Theme.textSecondary : Theme.background)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                saveState == .saved ? Theme.surfaceElevated : Theme.accent,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(saveState == .saved)
        .accessibilityLabel(saveState == .saved ? "Saved" : "Save question \(index)")
    }

    private var saveStateLabel: String {
        switch saveState {
        case .unsaved: return "Save"
        case .saved: return "Saved"
        case .dirty: return "Update"
        }
    }

    private var saveStateIcon: String {
        switch saveState {
        case .unsaved: return "square.and.arrow.down"
        case .saved: return "checkmark"
        case .dirty: return "square.and.pencil"
        }
    }

    // MARK: - Fields

    @ViewBuilder
    private func field(
        label: String,
        placeholder: String,
        systemImage: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            TextField(
                placeholder,
                text: text,
                axis: .vertical
            )
            .lineLimit(1...8)
            .font(.system(size: 15))
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.accent)
            .focused($focusedField, equals: field)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Theme.surfaceElevated,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        focusedField == field
                            ? Theme.accent.opacity(0.5)
                            : Theme.separator.opacity(0.6),
                        lineWidth: 1
                    )
            }
            .onChange(of: text.wrappedValue) { _, _ in
                onEdit()
            }
        }
    }
}
