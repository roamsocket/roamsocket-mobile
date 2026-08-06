import SwiftUI
import AnyProvCore

/// Sheet for creating a custom text skill. The user enters a name (becomes
/// the skill's `id` slug and frontmatter `name`), a one-line description,
/// and a markdown body. The save flow goes through `SkillsMCPClient` which
/// pushes the change to the desktop, which commits it to the user's
/// configured skills git repo.
struct CustomTextSkillEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var bodyText: String = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. swift-concurrency", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Used as the skill's id (slugified) and the SKILL.md name.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
                Section("Description") {
                    TextField("One-line summary", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("Body") {
                    TextEditor(text: $bodyText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
                    Text("Markdown. Injected into the agent's system prompt when the skill is enabled.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("New text skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!isValid || saving)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !description.isEmpty && !bodyText.isEmpty
    }

    private func save() {
        saving = true
        let slug = AppState.slugify(name)
        let skill = Skill(
            id: slug,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            content: bodyText,
            category: .other,
            source: .custom,
            isEnabled: true,
            frontmatter: [
                "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
                "description": description.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        )
        Task {
            do {
                try await state.skillsMCPClient.upsertSkill(skill, over: state.serverClient)
                state.skillManager.apply(skills: state.skillsMCPClient.cachedSkills)
                saving = false
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
