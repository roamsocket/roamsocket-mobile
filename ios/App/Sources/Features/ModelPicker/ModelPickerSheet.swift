import SwiftUI
import MobileAICore

/// The "Select model" bottom sheet (IMG_0988): models grouped by provider,
/// each with a subtitle, plus the Effort row.
struct ModelPickerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "Select model", trailing: nil, onClose: { dismiss() }) {
            ScrollView {
                VStack(spacing: 0) {
                    if state.isLoadingModels {
                        ProgressView().tint(Theme.textSecondary).padding(.vertical, 40)
                    } else if state.allModels.isEmpty {
                        emptyState
                    } else {
                        modelList
                    }

                    effortRow
                        .padding(.top, 12)
                }
                .padding(.horizontal, 20)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            if state.allModels.isEmpty { await state.refreshModels() }
        }
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            ForEach(state.providerResults) { result in
                if !result.models.isEmpty {
                    ForEach(result.models) { model in
                        SelectableRow(
                            title: model.displayName,
                            subtitle: subtitle(model, provider: result.provider),
                            isSelected: state.selectedModel?.id == model.id
                        ) {
                            state.selectedModel = model
                            dismiss()
                        }
                        Divider().overlay(Theme.separator)
                    }
                } else if let error = result.error {
                    Text("\(state.displayName(for: result.provider)): \(error)")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func subtitle(_ model: AIModel, provider: ProviderID) -> String {
        let name = state.displayName(for: provider)
        if let ctx = model.contextWindow {
            return "\(name) · \(ctx / 1000)K context"
        }
        return name
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
}
