import SwiftUI

/// "Create a project" bottom sheet (mirrors the second screenshot).
/// Two text fields: a single-line name field and a multi-line description
/// field for the project's goals. The check button is disabled until the
/// user has entered a name.
struct CreateProjectSheet: View {
    /// Called when the user confirms the new project. The host view is
    /// responsible for actually inserting the project into the store and
    /// navigating.
    var onCreate: (_ name: String, _ description: String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, description }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        nameSection
                        descriptionSection
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .onAppear { focusedField = .name }
    }

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Create a project")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Button(action: submit) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(canSubmit ? .white : Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .background(
                        canSubmit ? Theme.selection : Theme.surfaceElevated,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What are you working on?")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
            TextField("Name your project", text: $name)
                .focused($focusedField, equals: .name)
                .submitLabel(.next)
                .onSubmit { focusedField = .description }
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What are you trying to achieve?")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Theme.surface)
                if description.isEmpty {
                    Text("Describe your project, goals, subject, etc…")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                }
                TextEditor(text: $description)
                    .focused($focusedField, equals: .description)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(minHeight: 220)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(trimmedName, trimmedDescription)
        dismiss()
    }
}
