import SwiftUI
import AnyProvCore

/// Bottom sheet for choosing the default model for one conversation lane
/// (`chat`, `code`, or `vision`).
///
/// Mirrors the visual structure of `ModelPickerSheet` (provider groups, OpenRouter
/// submenus) but does NOT mutate `state.selectedModel`. Tapping a row writes the
/// stored id via `state.setDefaultModelID(...)` and dismisses.
///
/// "Use currently selected model" lets the user pin whatever is currently the
/// live picker selection as the default for this lane — handy when they've just
/// curated the perfect pick in the regular picker and want it to stick.
///
/// "Clear default" resets the stored id for the lane (the row stays open so the
/// user can pick something else).
///
/// OpenRouter submenu grouping lives in its own file-scope helper because
/// `ModelPickerSheet`'s `OpenRouterModelGroup` is `private` to that file and we
/// want the same shape here without exposing it across the module.
private struct DefaultModelOpenRouterGroup: Identifiable {
    let organization: String
    let models: [AIModel]
    var id: String { organization }
}

private func defaultModelOpenRouterGroups(_ models: [AIModel]) -> [DefaultModelOpenRouterGroup] {
    let groups = Dictionary(grouping: models) { model in
        model.organization
            ?? model.modelID.split(separator: "/", maxSplits: 1).first.map(String.init)
            ?? "Other"
    }
    return groups
        .map { DefaultModelOpenRouterGroup(organization: $0.key, models: $0.value) }
        .sorted {
            $0.organization.localizedCaseInsensitiveCompare($1.organization) == .orderedAscending
        }
}

struct DefaultModelSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let kind: AppState.DefaultModelKind

    @State private var expandedProviders: Set<ProviderID> = []
    @State private var expandedOpenRouterOrgs: Set<String> = []

    /// Models visible in the picker for this lane, with provider filter applied.
    private var results: [ModelCatalog.ProviderResult] {
        switch kind {
        case .chat:
            return state.providerResults
        case .code:
            // Same rules as ModelPickerSheet(codingOnly: true): exclude phone
            // Metal (weights may not match the desktop), and append the desktop
            // Metal inventory if paired.
            var codeResults = state.providerResults.filter {
                $0.provider.supportsCodingAgent && $0.provider != .localMetal
            }
            if !state.desktopMetalModels.isEmpty || state.desktopMetalError != nil {
                codeResults.append(
                    ModelCatalog.ProviderResult(
                        provider: .localMetal,
                        models: state.desktopMetalModels,
                        error: state.desktopMetalModels.isEmpty ? state.desktopMetalError : nil
                    )
                )
            }
            return codeResults
        case .vision:
            // Vision uses phone-side providers; desktop Metal is chat-only on the
            // server (we never send images over WS to the agent). Phone Metal
            // only counts if it's a known vision hub — `modelSupportsVision`
            // already handles that.
            return state.providerResults.filter { result in
                state.visibleModels(in: result).contains(where: { state.modelSupportsVision($0) })
            }
        }
    }

    private var nonEmptyResults: [ModelCatalog.ProviderResult] {
        results.filter { result in
            !filteredModels(in: result).isEmpty
        }
    }

    private var emptyResults: [ModelCatalog.ProviderResult] {
        results.filter { $0.models.isEmpty && ($0.error != nil) }
    }

    private var hasAnyListedModels: Bool {
        results.contains { !filteredModels(in: $0).isEmpty }
    }

    /// Lane-specific model filter. Hidden models never show up regardless of lane.
    private func filteredModels(in result: ModelCatalog.ProviderResult) -> [AIModel] {
        let visible = state.visibleModels(in: result)
        switch kind {
        case .chat:
            return visible
        case .code:
            return visible.filter { $0.provider.supportsCodingAgent }
        case .vision:
            return visible.filter { state.modelSupportsVision($0) }
        }
    }

    var body: some View {
        SheetScaffold(
            title: "Default model for \(kind.title)",
            trailing: nil,
            onClose: { dismiss() }
        ) {
            List {
                Section {
                    headerRow
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                }

                if state.isLoadingModels
                    || (kind == .code && state.isLoadingDesktopMetal && !hasAnyListedModels) {
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

                Section {
                    actionsFooter
                        .listRowBackground(Theme.surface)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .task {
                if let def = state.defaultModel(for: kind) {
                    expandedProviders.insert(def.provider)
                    if def.provider == .openrouter {
                        let org = def.organization
                            ?? def.modelID.split(separator: "/", maxSplits: 1).first.map(String.init)
                            ?? "Other"
                        expandedOpenRouterOrgs.insert(org)
                    }
                }
                if state.allModels.isEmpty { await state.refreshModels() }
                if kind == .code { await state.refreshDesktopMetalModels() }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(kind.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Provider sections

    @ViewBuilder
    private func providerSection(result: ModelCatalog.ProviderResult) -> some View {
        let models = filteredModels(in: result)
        Section {
            DisclosureGroup(isExpanded: providerBinding(for: result.provider)) {
                if result.provider == .openrouter {
                    // Same OpenRouter submenu grouping as ModelPickerSheet so
                    // giant catalogs don't render as a single endless list.
                    ForEach(defaultModelOpenRouterGroups(models)) { group in
                        DisclosureGroup(isExpanded: expandedBinding(for: group.id)) {
                            ForEach(group.models) { model in
                                modelRow(model)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(AIModel.prettifiedDisplayName(for: group.organization))
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(group.models.count)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textTertiary)
                                Spacer(minLength: 0)
                            }
                        }
                        .tint(Theme.textSecondary)
                        .listRowBackground(Theme.surface)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                } else {
                    ForEach(models) { model in
                        modelRow(model)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(providerTitle(for: result))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(models.count) model\(models.count == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
            }
            .tint(Theme.textSecondary)
            .listRowBackground(Theme.surface)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private func providerTitle(for result: ModelCatalog.ProviderResult) -> String {
        if kind == .code, result.provider == .localMetal {
            return "Desktop Metal"
        }
        return state.customProvider(for: result.provider)?.label ?? result.provider.displayName
    }

    private func modelRow(_ model: AIModel) -> some View {
        let isCurrent = state.defaultModelID(for: kind) == model.id
        return Button {
            state.setDefaultModelID(model.id, for: kind)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.displayName(for: model))
                        .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                    Text(providerLabel(for: model.provider))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    /// Provider label for a single model — mirrors `providerTitle(for result:)`
    /// but operates on a lone model instead of a full `ProviderResult`.
    private func providerLabel(for provider: ProviderID) -> String {
        if kind == .code, provider == .localMetal { return "Desktop Metal" }
        return state.customProvider(for: provider)?.label ?? provider.displayName
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

    private func expandedBinding(for org: String) -> Binding<Bool> {
        Binding(
            get: { expandedOpenRouterOrgs.contains(org) },
            set: { expanded in
                if expanded { expandedOpenRouterOrgs.insert(org) }
                else { expandedOpenRouterOrgs.remove(org) }
            }
        )
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
        switch kind {
        case .chat:
            return "Add an API key in Settings, pick Apple Intelligence when available, or download an on-device Metal model (Settings → On-device)."
        case .code:
            return "Coding runs on your paired desktop. Add an API key for Anthropic, OpenAI, OpenRouter, xAI, or Mistral in Settings, or install Metal models on the desktop."
        case .vision:
            return "Vision needs a vision-capable model. Add an API key for OpenAI, Anthropic, OpenRouter, or xAI, or download an on-device Metal vision model."
        }
    }

    // MARK: - Footer actions

    @ViewBuilder
    private var actionsFooter: some View {
        VStack(spacing: 0) {
            Divider().background(Theme.separator)

            if let current = state.selectedModel,
               state.modelMeetsLane(current, kind: kind) {
                Button {
                    state.setDefaultModelID(current.id, for: kind)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use currently selected model")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text(state.displayName(for: current))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().background(Theme.separator)
            }

            Button(role: .destructive) {
                state.setDefaultModelID(nil, for: kind)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                        .frame(width: 24)
                    Text("Clear default")
                        .font(.system(size: 15, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.defaultModelID(for: kind).isEmpty)
            .opacity(state.defaultModelID(for: kind).isEmpty ? 0.4 : 1)
        }
    }
}