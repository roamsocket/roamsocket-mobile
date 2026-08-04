import SwiftUI

/// Root navigation: the Home composer, pushing to a coding Session when a task
/// is submitted, with Settings reachable from the top bar.
struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            HomeView()
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            CloudGlyph()
                            Text(state.selectedEnvironment?.name ?? "Default")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                .toolbarBackground(Theme.background, for: .navigationBar)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            if state.allModels.isEmpty { await state.refreshModels() }
        }
    }
}
