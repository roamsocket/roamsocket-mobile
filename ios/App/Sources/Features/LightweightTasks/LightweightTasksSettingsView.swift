import SwiftUI
import AnyProvCore

/// Settings for short helper generations (titles, artifact names, commits, …).
struct LightweightTasksSettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var settings = LightweightTasksSettings.load()
    @State private var status = ""

    private var linkedModels: [AIModel] {
        guard let provider = settings.linkedProvider else { return [] }
        return state.providerResults
            .first(where: { $0.provider == provider })
            .map { state.visibleModels(in: $0) }
            ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Lightweight Tasks power short jobs like chat titles, artifact names, commit subjects, and thinking summaries. They stay separate from your main chat model.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }

                Section {
                    Picker("Backend", selection: $settings.mode) {
                        if LightweightTaskRunner.appleFoundationAvailable
                            || settings.mode == .appleFoundation {
                            Text(LightweightTasksSettings.Mode.appleFoundation.displayName)
                                .tag(LightweightTasksSettings.Mode.appleFoundation)
                        }
                        Text(LightweightTasksSettings.Mode.linkedModel.displayName)
                            .tag(LightweightTasksSettings.Mode.linkedModel)
                    }
                    .onChange(of: settings.mode) { _, _ in persist() }
                } footer: {
                    Text(settings.mode.detail)
                }

                if settings.mode == .appleFoundation {
                    Section("Apple Intelligence") {
                        HStack {
                            Text("Status")
                            Spacer()
                            Text(LightweightTaskRunner.appleFoundationStatusLine)
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                if settings.mode == .linkedModel {
                    Section {
                        Picker("Provider", selection: linkedProviderBinding) {
                            Text("Select…").tag(String?.none)
                            ForEach(ProviderID.allBuiltInCases.filter { $0.supportsCodingAgent || $0 == .google }) { p in
                                Text(p.displayName).tag(Optional(p.rawValue))
                            }
                            ForEach(state.customProviders) { c in
                                Text(c.label).tag(Optional(c.providerID.rawValue))
                            }
                        }
                        if settings.linkedProvider != nil {
                            if linkedModels.isEmpty {
                                Text("No models loaded for this provider. Add a key and refresh models.")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textSecondary)
                                Button("Refresh models") {
                                    Task {
                                        await state.refreshModels()
                                        status = "Model list updated."
                                    }
                                }
                            } else {
                                Picker("Model", selection: linkedModelBinding) {
                                    Text("Select…").tag(String?.none)
                                    ForEach(linkedModels) { m in
                                        Text(state.displayName(for: m)).tag(Optional(m.modelID))
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Linked model")
                    } footer: {
                        Text("Used for Lightweight Tasks only — not your main chat or coding agent unless you pick the same model there too.")
                    }
                }

                if !status.isEmpty {
                    Section {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Lightweight Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        persist()
                        dismiss()
                    }
                }
            }
            .onAppear {
                settings = LightweightTasksSettings.load()
            }
        }
    }

    private var linkedProviderBinding: Binding<String?> {
        Binding(
            get: { settings.linkedProviderRaw },
            set: { newValue in
                settings.linkedProviderRaw = newValue
                settings.linkedModelID = nil
                persist()
                Task { await state.refreshModels() }
            }
        )
    }

    private var linkedModelBinding: Binding<String?> {
        Binding(
            get: { settings.linkedModelID },
            set: { newValue in
                settings.linkedModelID = newValue
                persist()
            }
        )
    }

    private func persist() {
        settings.save()
    }
}
