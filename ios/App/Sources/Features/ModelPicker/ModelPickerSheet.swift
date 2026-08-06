import SwiftUI
import MobileAICore

/// "Select model" bottom sheet:
///   - grouped by provider, each provider gets a section header
///   - tapping a model selects it
///   - long-pressing (or the chevron) opens a rename sheet for an alias
///   - Effort lives at the bottom as before
struct ModelPickerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var renameTarget: AIModel?

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

                    effortRow
                        .padding(.top, 16)
                }
                .padding(.horizontal, 20)
            }
            .task {
                if state.allModels.isEmpty { await state.refreshModels() }
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
                        onSelect: {
                            state.selectedModel = model
                            dismiss()
                        },
                        onRename: { renameTarget = model }
                    )
                    if idx < result.models.count - 1 {
                        Divider().overlay(Theme.separator)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func providerTitle(for result: ModelCatalog.ProviderResult) -> String {
        state.customProvider(for: result.provider)?.label ?? result.provider.displayName
    }

    private func providerDisplayName(for result: ModelCatalog.ProviderResult) -> String {
        // Subtitle beneath the model name; falls back to provider name.
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
            Text("Add an API key in Settings to load models from your providers.")
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
}

// MARK: - Row

private struct ModelRow: View {
    @EnvironmentObject var state: AppState
    let model: AIModel
    let isSelected: Bool
    let providerDisplayName: String
    var onSelect: () -> Void
    var onRename: () -> Void

    private var contextSubtitle: String? {
        if let ctx = model.contextWindow {
            return "\(providerDisplayName) · \(ctx / 1000)K context"
        }
        return providerDisplayName
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
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.selection)
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