import SwiftUI
import MobileAICore

/// The "Choose environment" bottom sheet (IMG_0989).
struct EnvironmentPickerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false

    var body: some View {
        SheetScaffold(
            title: "Choose environment",
            trailing: AnyView(
                Button { showNew = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
            ),
            onClose: { dismiss() }
        ) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(state.environments) { env in
                        SelectableRow(
                            title: env.name,
                            isSelected: state.selectedEnvironment?.name == env.name,
                            leading: { CloudGlyph() }
                        ) {
                            state.selectedEnvironment = env
                            dismiss()
                        }
                        .contextMenu {
                            Button(role: .destructive) { state.delete(env) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        Divider().overlay(Theme.separator)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showNew) {
            NewEnvironmentView { env in
                state.addOrUpdate(env)
                state.selectedEnvironment = env
            }
        }
    }
}
