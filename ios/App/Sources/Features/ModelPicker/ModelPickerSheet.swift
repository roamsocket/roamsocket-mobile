import SwiftUI
import AnyProvCore

/// "Select model" bottom sheet:
///   - grouped by provider, each provider gets a section header
///   - tapping a model selects it
///   - long-pressing (or the chevron) opens a rename sheet for an alias
///   - local Metal models can be unloaded from RAM without deleting weights
///   - Effort lives at the bottom as before
struct ModelPickerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var renameTarget: AIModel?
    @State private var loadedMetalIDs: Set<String> = []
    @State private var statusMessage = ""

    private var nonEmptyResults: [ModelCatalog.ProviderResult] {
        state.providerResults.filter { !$0.models.isEmpty }
    }

    private var emptyResults: [ModelCatalog.ProviderResult] {
        state.providerResults.filter { $0.models.isEmpty && ($0.error != nil) }
    }

    var body: some View {
        SheetScaffold(title: "Select model", trailing: nil, onClose: { dismiss() }) {
            ScrollView {
                VStack(spacing: 0) {
                    if state.isLoadingModels {
                        ProgressView().tint(Theme.textSecondary).padding(.vertical, 40)
                    } else if state.allModels.isEmpty {
                        emptyState
                    } else {
                        sections
                    }

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                    }

                    if !loadedMetalIDs.isEmpty {
                        unloadAllRow
                            .padding(.top, 12)
                    }

                    effortRow
                        .padding(.top, 16)
                }
                .padding(.horizontal, 20)
            }
            .task {
                LocalMetalBootstrap.ensureRegistered()
                if state.allModels.isEmpty { await state.refreshModels() }
                await refreshLoadedMetal()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $renameTarget) { model in
            RenameModelSheet(model: model)
        }
    }

    private var sections: some View {
        VStack(spacing: 18) {
            ForEach(nonEmptyResults) { result in
                providerSection(result: result)
            }
            ForEach(emptyResults) { result in
                errorRow(result: result)
            }
        }
    }

    @ViewBuilder
    private func providerSection(result: ModelCatalog.ProviderResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(providerTitle(for: result))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(result.models.enumerated()), id: \.element.id) { idx, model in
                    ModelRow(
                        model: model,
                        isSelected: state.selectedModel?.id == model.id,
                        providerDisplayName: providerDisplayName(for: result),
                        isLoadedInMemory: model.provider == .localMetal
                            && loadedMetalIDs.contains(model.modelID),
                        onSelect: {
                            state.selectedModel = model
                            dismiss()
                        },
                        onRename: { renameTarget = model },
                        onUnload: model.provider == .localMetal
                            ? { Task { await unload(model.modelID) } }
                            : nil
                    )
                    if idx < result.models.count - 1 {
                        Divider().overlay(Theme.separator)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var unloadAllRow: some View {
        Button {
            Task { await unloadAll() }
        } label: {
            HStack {
                Image(systemName: "memorychip")
                Text("Unload all Metal models from memory")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Theme.accent)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func providerTitle(for result: ModelCatalog.ProviderResult) -> String {
        state.customProvider(for: result.provider)?.label ?? result.provider.displayName
    }

    private func providerDisplayName(for result: ModelCatalog.ProviderResult) -> String {
        let base = state.customProvider(for: result.provider)?.label ?? result.provider.displayName
        return base
    }

    @ViewBuilder
    private func errorRow(result: ModelCatalog.ProviderResult) -> some View {
        if let error = result.error {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.provider.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No models yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Add an API key in Settings, or download an on-device Metal model (Settings → On-device).")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
    }

    private var effortRow: some View {
        Menu {
            ForEach(Effort.allCases, id: \.self) { effort in
                Button {
                    state.effort = effort
                } label: {
                    Label(effort.displayName, systemImage: state.effort == effort ? "checkmark" : "")
                }
            }
        } label: {
            HStack {
                Text("Effort")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(state.effort.displayName)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 20)
            .background(Theme.surface, in: Capsule())
        }
    }

    private func refreshLoadedMetal() async {
        LocalMetalBootstrap.ensureRegistered()
        guard let engine = LocalMetalRuntime.engine else {
            loadedMetalIDs = []
            return
        }
        let ids = await engine.loadedModelIDs()
        loadedMetalIDs = Set(ids)
    }

    private func unload(_ modelID: String) async {
        LocalMetalBootstrap.ensureRegistered()
        guard let engine = LocalMetalRuntime.engine else { return }
        await engine.unloadFromMemory(modelID: modelID)
        await refreshLoadedMetal()
        statusMessage = "Unloaded from memory (weights stay on disk)."
    }

    private func unloadAll() async {
        LocalMetalBootstrap.ensureRegistered()
        guard let engine = LocalMetalRuntime.engine else { return }
        await engine.unloadAllFromMemory()
        await refreshLoadedMetal()
        statusMessage = "All Metal models unloaded from memory."
    }
}

// MARK: - Row

private struct ModelRow: View {
    @EnvironmentObject var state: AppState
    let model: AIModel
    let isSelected: Bool
    let providerDisplayName: String
    var isLoadedInMemory: Bool = false
    var onSelect: () -> Void
    var onRename: () -> Void
    var onUnload: (() -> Void)?

    private var contextSubtitle: String? {
        var parts: [String] = [providerDisplayName]
        if let ctx = model.contextWindow {
            parts.append("\(ctx / 1000)K context")
        }
        if isLoadedInMemory {
            parts.append("In memory")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.displayName(for: model))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if let contextSubtitle {
                        Text(contextSubtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(isLoadedInMemory ? Theme.accent : Theme.textTertiary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.selection)
                }
                if isLoadedInMemory, let onUnload {
                    Button {
                        onUnload()
                    } label: {
                        Text("Unload")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unload \(state.displayName(for: model)) from memory")
                }
                Button(action: onRename) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename \(state.displayName(for: model))")
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isLoadedInMemory, let onUnload {
                Button("Unload from memory", systemImage: "memorychip") {
                    onUnload()
                }
            }
            Button("Rename", systemImage: "pencil") {
                onRename()
            }
        }
    }
}

// MARK: - Rename sheet

private struct RenameModelSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let model: AIModel

    @State private var alias: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Original name")
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(model.displayName)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                    }
                } footer: {
                    Text("This alias only changes how the model appears in this app. The wire-level model id sent to providers is unchanged.")
                }

                Section("Display name") {
                    TextField("Alias", text: $alias)
                        .textInputAutocapitalization(.words)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Rename model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        state.setAlias(alias, for: model.provider, modelID: model.modelID)
                        dismiss()
                    }
                    .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !alias.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Reset to upstream") {
                            state.setAlias(nil, for: model.provider, modelID: model.modelID)
                            dismiss()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            alias = state.displayName(for: model)
        }
    }
}
