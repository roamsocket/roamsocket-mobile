import SwiftUI
import MobileAICore

/// View for managing connectors (formerly "MCP servers"). The underlying
/// manager is still `MCPManager`; only the user-facing name changed.
struct ConnectorManagerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showAddServer = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if state.mcpManager.configuredServers.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 48))
                            .foregroundStyle(Theme.textTertiary)
                        Text("No connectors")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Text("Add connectors via the + button. They're synced from your connector repo.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section("Configured Connectors") {
                            ForEach(state.mcpManager.configuredServers) { server in
                                MCPServerRow(server: server) {
                                    state.mcpManager.toggleServer(server.id)
                                }
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    let server = state.mcpManager.configuredServers[index]
                                    Task {
                                        try? await state.skillsMCPClient.deleteMCPServer(
                                            id: server.id,
                                            over: state.serverClient
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Connectors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddServer = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddServer) {
                AddConnectorView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct MCPServerRow: View {
    let server: MCPServer
    let onToggle: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 6))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(server.description)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}


