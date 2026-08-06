import SwiftUI
import AnyProvCore

/// Enable on-device Metal models for **chat only** (not coding sessions).
struct LocalMetalSettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var enabled: Set<String> = []
    @State private var busy = false
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Run small open models on this device with Metal (MLX). Chat only — coding sessions always use a cloud or desktop provider.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }

                Section("Available models") {
                    ForEach(LocalMetalModelStore.catalogPresets, id: \.id) { preset in
                        Toggle(isOn: Binding(
                            get: { enabled.contains(preset.id) },
                            set: { on in
                                Task {
                                    await LocalMetalModelStore.shared.setEnabled(on, modelID: preset.id)
                                    await reload()
                                    await state.refreshModels()
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.system(size: 16, weight: .medium))
                                Text(preset.id)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        .tint(Theme.accent)
                    }
                }

                Section {
                    Button("Refresh model list") {
                        Task {
                            busy = true
                            await state.refreshModels()
                            busy = false
                            status = "Updated."
                        }
                    }
                    .disabled(busy)
                    if !status.isEmpty {
                        Text(status).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                } footer: {
                    Text("First chat with a model downloads weights over the network (Hugging Face). Later runs stay on-device via Metal/MLX. Coding sessions never use these models — chat only.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("On-device (Metal)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reload() }
        }
        .preferredColorScheme(.dark)
    }

    private func reload() async {
        let ids = await LocalMetalModelStore.shared.enabledModelIDs()
        enabled = Set(ids)
    }
}
