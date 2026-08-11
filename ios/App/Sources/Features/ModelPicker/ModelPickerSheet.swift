import SwiftUI
import AnyProvCore

/// "Select model" bottom sheet:
///   - grouped by provider, each provider gets a section header
///   - tapping a model selects it
///   - swipe **Edit** (rename alias) or **Delete** (hide from list / erase Metal weights)
///   - local Metal models can be unloaded from RAM without deleting weights
///   - Effort lives at the bottom as before
///
/// When `codingOnly` is true (coding session / new session), phone-local Metal
/// and other phone-only providers are hidden. Desktop-installed Metal models
/// (from the paired server) are listed instead so weights match the agent host.
struct ModelPickerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// When true, only list providers the desktop coding agent can drive.
    /// Hides phone Metal / Apple Intelligence; shows desktop Metal inventory.
    var codingOnly: Bool = false

    @State private var renameTarget: AIModel?
    @State private var loadedMetalIDs: Set<String> = []
    @State private var statusMessage = ""
    @State private var expandedProviders: Set<ProviderID> = []
    @State private var expandedOpenRouterOrgs: Set<String> = []

    private var catalogResults: [ModelCatalog.ProviderResult] {
        if codingOnly {
            // Cloud / custom providers the agent supports — never phone Metal.
            var results = state.providerResults.filter {
                $0.provider.supportsCodingAgent && $0.provider != .localMetal
            }
            // Desktop Metal inventory (paired server), not phone weights.
            if !state.desktopMetalModels.isEmpty || state.desktopMetalError != nil {
                results.append(
                    ModelCatalog.ProviderResult(
                        provider: .localMetal,
                        models: state.desktopMetalModels,
                        error: state.desktopMetalModels.isEmpty ? state.desktopMetalError : nil
                    )
                )
            }
            return results
        }
        return state.providerResults
    }

    private var nonEmptyResults: [ModelCatalog.ProviderResult] {
        catalogResults.filter { !state.visibleModels(in: $0).isEmpty }
    }

    private var emptyResults: [ModelCatalog.ProviderResult] {
        catalogResults.filter { $0.models.isEmpty && ($0.error != nil) }
    }

    private var hasAnyListedModels: Bool {
        catalogResults.contains { !state.visibleModels(in: $0).isEmpty }
    }

    var body: some View {
        SheetScaffold(title: "Select model", trailing: nil, onClose: { dismiss() }) {
            List {
                if state.isLoadingModels || (codingOnly && state.isLoadingDesktopMetal && !hasAnyListedModels) {
                    ProgressView()
                        .tint(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if !hasAnyListedModels {
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

                // Metal load/unload controls only apply when phone Metal models are listed.
                if !codingOnly {
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

                if !codingOnly, !loadedMetalIDs.isEmpty {
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
                if let selected = state.selectedModel {
                    expandedProviders.insert(selected.provider)
                    if selected.provider == .openrouter {
                        let org = selected.organization
                            ?? selected.modelID.split(separator: "/", maxSplits: 1).first.map(String.init)
                            ?? "Other"
                        expandedOpenRouterOrgs.insert(org)
                    }
                }
                if !codingOnly {
                    LocalMetalBootstrap.ensureRegistered()
                }
                if state.allModels.isEmpty { await state.refreshModels() }
                if codingOnly {
                    await state.refreshDesktopMetalModels()
                } else {
                    await refreshLoadedMetal()
                }
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
            DisclosureGroup(isExpanded: providerBinding(for: result.provider)) {
                if result.provider == .openrouter {
                    // OpenRouter's catalog is huge — nest it as submenus, one
                    // per vendor / organization tag (e.g. OpenAI, Anthropic).
                    ForEach(Self.openRouterModelGroups(models)) { group in
                        DisclosureGroup(isExpanded: expandedBinding(for: group.id)) {
                            ForEach(group.models) { model in
                                modelRow(model, result: result)
                            }
                        } label: {
                            openRouterSubmenuLabel(
                                title: group.organization,
                                detail: "\(group.models.count)"
                            )
                        }
                        .tint(Theme.textSecondary)
                        .listRowBackground(Theme.surface)
                    }
                } else {
                    ForEach(models) { model in
                        modelRow(model, result: result)
                    }
                }
            } label: {
                openRouterSubmenuLabel(
                    title: providerTitle(for: result),
                    detail: "\(models.count) model\(models.count == 1 ? "" : "s")"
                )
            }
            .tint(Theme.textSecondary)
            .listRowBackground(Theme.surface)
        }
    }

    private func providerBinding(for provider: ProviderID) -> Binding<Bool> {
        Binding(
            get: { expandedProviders.contains(provider) },
            set: { expanded in
                if expanded { expandedProviders.insert(provider) }
                else { expandedProviders.remove(provider) }
            }
        )
    }

    private func openRouterSubmenuLabel(title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
    }

    private func expandedBinding(for org: String) -> Binding<Bool> {
        Binding(
            get: { expandedOpenRouterOrgs.contains(org) },
            set: { expanded in
                if expanded { expandedOpenRouterOrgs.insert(org) }
                else { expandedOpenRouterOrgs.remove(org) }
            }
        )
    }

    /// Group OpenRouter models by their organization tag; fall back to the
    /// vendor prefix of the model id ("anthropic/claude…" → "anthropic").
    fileprivate static func openRouterModelGroups(_ models: [AIModel]) -> [OpenRouterModelGroup] {
        let groups = Dictionary(grouping: models) { model in
            model.organization
                ?? model.modelID.split(separator: "/", maxSplits: 1).first.map(String.init)
                ?? "Other"
        }
        return groups
            .map { OpenRouterModelGroup(organization: $0.key, models: $0.value) }
            .sorted {
                $0.organization.localizedCaseInsensitiveCompare($1.organization) == .orderedAscending
            }
    }

    private func modelRow(
        _ model: AIModel,
        result: ModelCatalog.ProviderResult
    ) -> some View {
        ModelRow(
            model: model,
            isSelected: state.selectedModel?.id == model.id,
            providerDisplayName: providerDisplayName(for: result),
            isLoadedInMemory: !codingOnly
                && model.provider == .localMetal
                && loadedMetalIDs.contains(model.modelID),
            onSelect: {
                // Selection triggers AppState local-Metal load/unload policy
                // only for phone weights; desktop Metal runs on the server.
                state.selectedModel = model
                dismiss()
            },
            onUnload: (!codingOnly && model.provider == .localMetal)
                ? { Task { await unload(model.modelID) } }
                : nil
        )
        .listRowBackground(Theme.surface)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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
            if !codingOnly,
               model.provider == .localMetal,
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
                    !codingOnly && model.provider == .localMetal
                        ? "Delete from disk"
                        : "Remove from list",
                    systemImage: "trash"
                )
            }
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
        if codingOnly, result.provider == .localMetal {
            return "Desktop Metal"
        }
        return state.customProvider(for: result.provider)?.label ?? result.provider.displayName
    }

    private func providerDisplayName(for result: ModelCatalog.ProviderResult) -> String {
        if codingOnly, result.provider == .localMetal {
            return "Desktop Metal"
        }
        return state.customProvider(for: result.provider)?.label ?? result.provider.displayName
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
            Text(emptyStateMessage)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyStateMessage: String {
        if codingOnly {
            return "Coding runs on your paired desktop. Add an API key in Settings (Anthropic, OpenAI, OpenRouter, …) or download Metal models in the desktop app (Settings → On-device Metal). Phone Metal models are hidden here because weights may not match the server."
        }
        return "Add an API key in Settings, pick Apple Intelligence when available, or download an on-device Metal model (Settings → On-device)."
    }

    private var effortRow: some View {
        EffortControl(effort: $state.effort)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
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

/// A vendor subfolder inside the OpenRouter section of the model picker.
private struct OpenRouterModelGroup: Identifiable {
    let organization: String
    let models: [AIModel]
    var id: String { organization }
}

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

    private var supportsVision: Bool {
        state.modelSupportsVision(model)
    }

    var body: some View {
        // Prefer tap gesture over an outer Button so trailing swipe actions
        // (Edit / Delete) aren't stolen by the selection control.
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(state.displayName(for: model))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if model.isFree == true {
                        Text("Free")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.15), in: Capsule())
                    }
                    if supportsVision {
                        Text("Vision")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.yellow)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.yellow.opacity(0.18), in: Capsule())
                    }
                }
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
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel(
            supportsVision
                ? "\(state.displayName(for: model)), supports vision"
                : state.displayName(for: model)
        )
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
