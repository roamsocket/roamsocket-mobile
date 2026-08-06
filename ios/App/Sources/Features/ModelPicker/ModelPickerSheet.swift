import SwiftUI
import AnyProvCore

/// "Select model" bottom sheet:
///   - grouped by provider, each provider gets a section header
///   - tapping a model selects it
///   - swipe **Edit** (rename alias) or **Delete** (hide from list / erase Metal weights)
///   - local Metal models can be unloaded from RAM without deleting weights
///   - Effort lives at the bottom as before
struct ModelPickerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var renameTarget: AIModel?
    @State private var loadedMetalIDs: Set<String> = []
    @State private var statusMessage = ""

    private var nonEmptyResults: [ModelCatalog.ProviderResult] {
        state.providerResults.filter { !state.visibleModels(in: $0).isEmpty }
    }

    private var emptyResults: [ModelCatalog.ProviderResult] {
        state.providerResults.filter { $0.models.isEmpty && ($0.error != nil) }
    }

    var body: some View {
        SheetScaffold(title: "Select model", trailing: nil, onClose: { dismiss() }) {
            List {
                if state.isLoadingModels {
                    ProgressView()
                        .tint(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if state.allModels.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(nonEmptyResults) { result in
                        providerSection(result: result)
                    }
                    ForEach(emptyResults) { result in
                        Section {
                            errorRow(result: result)
                                .listRowBackground(Theme.surface)
                                .listRowSeparator(.hidden)
                        }
                    }
                }

                if state.isLoadingLocalMetal {
                    Section {
                        LocalMetalLoadProgressBanner(
                            progress: state.localMetalLoadProgress,
                            modelName: state.selectedModel.map { state.displayName(for: $0) },
                            style: .plain
                        )
                        .listRowBackground(Theme.surface)
                        .listRowSeparator(.hidden)
                    }
                } else if let err = state.localMetalLoadError, !err.isEmpty {
                    Section {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.9))
                            .listRowBackground(Theme.surface)
                            .listRowSeparator(.hidden)
                    }
                }

                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .listRowBackground(Theme.surface)
                            .listRowSeparator(.hidden)
                    }
                }

                if !loadedMetalIDs.isEmpty {
                    Section {
                        unloadAllRow
                            .listRowBackground(Theme.surface)
                            .listRowSeparator(.hidden)
                    }
                }

                if state.hasHiddenModels {
                    Section {
                        Button {
                            state.restoreHiddenModels()
                            statusMessage = "Restored hidden models to the list."
                        } label: {
                            Label("Show hidden models", systemImage: "eye")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.surface)
                        .listRowSeparator(.hidden)
                        .accessibilityHint("Bring back models you removed with swipe Delete")
                    }
                }

                Section {
                    effortRow
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                }
            }
            // Inset grouped = rounded card sections (native iOS). Keeps swipeActions.
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
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

    @ViewBuilder
    private func providerSection(result: ModelCatalog.ProviderResult) -> some View {
        let models = state.visibleModels(in: result)
        Section {
            ForEach(models) { model in
                ModelRow(
                    model: model,
                    isSelected: state.selectedModel?.id == model.id,
                    providerDisplayName: providerDisplayName(for: result),
                    isLoadedInMemory: model.provider == .localMetal
                        && loadedMetalIDs.contains(model.modelID),
                    onSelect: {
                        // Selection triggers AppState local-Metal load/unload policy.
                        state.selectedModel = model
                        dismiss()
                    },
                    onUnload: model.provider == .localMetal
                        ? { Task { await unload(model.modelID) } }
                        : nil
                )
                .listRowBackground(Theme.surface)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await deleteModel(model) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        renameTarget = model
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(Theme.accent)
                }
                .contextMenu {
                    Button {
                        renameTarget = model
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    if model.provider == .localMetal,
                       loadedMetalIDs.contains(model.modelID) {
                        Button {
                            Task { await unload(model.modelID) }
                        } label: {
                            Label("Unload from memory", systemImage: "memorychip")
                        }
                    }
                    Button(role: .destructive) {
                        Task { await deleteModel(model) }
                    } label: {
                        Label(
                            model.provider == .localMetal ? "Delete from disk" : "Remove from list",
                            systemImage: "trash"
                        )
                    }
                }
            }
        } header: {
            Text(providerTitle(for: result))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
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
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func providerTitle(for result: ModelCatalog.ProviderResult) -> String {
        state.customProvider(for: result.provider)?.label ?? result.provider.displayName
    }

    private func providerDisplayName(for result: ModelCatalog.ProviderResult) -> String {
        state.customProvider(for: result.provider)?.label ?? result.provider.displayName
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
            .padding(.vertical, 6)
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
        .frame(maxWidth: .infinity)
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

    private func deleteModel(_ model: AIModel) async {
        do {
            let message = try await state.removeModelFromPicker(model)
            statusMessage = message
            if model.provider == .localMetal {
                await refreshLoadedMetal()
            }
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
        // Prefer tap gesture over an outer Button so trailing swipe actions
        // (Edit / Delete) aren't stolen by the selection control.
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
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel(state.displayName(for: model))
        .accessibilityHint("Select model")
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
            .navigationTitle("Edit model")
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
        .onAppear {
            alias = state.displayName(for: model)
        }
    }
}
