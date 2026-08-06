import SwiftUI

/// Edit-title sheet with a sparkles control that fills the field from the
/// chat content (Apple Foundation Model when available).
struct RenameChatSheet: View {
    let initialTitle: String
    /// Returns a suggested title from chat messages, or nil on failure.
    let onGenerate: () async -> String?
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String = ""
    @State private var isGenerating = false
    @State private var generateError: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose a short name for this chat.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 10) {
                    TextField("Title", text: $draft)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit(saveIfValid)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.separator.opacity(0.7), lineWidth: 1)
                        )

                    generateButton
                }

                if let generateError {
                    Text(generateError)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.orange)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Rename chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveIfValid()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .onAppear {
                draft = initialTitle
                titleFocused = true
            }
        }
        .presentationDetents([.height(220), .medium])
        .presentationDragIndicator(.visible)
    }

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var generateButton: some View {
        Button {
            Task { await generate() }
        } label: {
            Group {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.accent)
            .frame(width: 44, height: 44)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.separator.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
        .accessibilityLabel("Generate title")
        .accessibilityHint("Suggests a name from this chat’s messages")
    }

    private func saveIfValid() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }

    private func generate() async {
        generateError = nil
        isGenerating = true
        defer { isGenerating = false }
        if let title = await onGenerate(),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = title
            titleFocused = true
        } else {
            generateError = "Couldn’t generate a title from this chat yet."
        }
    }
}
