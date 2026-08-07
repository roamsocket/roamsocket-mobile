import SwiftUI
import AnyProvCore

/// Connectors list view. Shows marketplace catalog connectors (discovery)
/// plus MCP servers synced from the user's connector repo via the desktop.
struct ConnectorsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var marketplace = MarketplaceStore.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(spacing: 16) {
                            discoveryToggle
                                .padding(.horizontal, 16)
                                .padding(.top, 16)

                            if !marketplace.connectors.isEmpty {
                                sectionHeader("Marketplace")
                                marketplaceConnectorsList
                            }

                            if !state.mcpManager.configuredServers.isEmpty {
                                sectionHeader("Configured (synced)")
                                connectorsList
                            } else if marketplace.connectors.isEmpty {
                                emptyState
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
            }
            .navigationBarHidden(true)
            .task {
                if marketplace.connectors.isEmpty {
                    await marketplace.refresh()
                }
                viewModel.applyMarketplaceConnectors(marketplace.connectors)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }

    private var marketplaceConnectorsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(marketplace.connectors.enumerated()), id: \.element.id) { index, item in
                let available = item.isAvailable
                HStack(spacing: 14) {
                    Image(systemName: item.icon ?? "puzzlepiece.extension")
                        .font(.system(size: 20))
                        .foregroundStyle(available ? Theme.textPrimary : Theme.textTertiary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 17))
                            .foregroundStyle(available ? Theme.textPrimary : Theme.textTertiary)
                        if let d = item.description, !d.isEmpty {
                            Text(d)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if available {
                        Toggle("", isOn: Binding(
                            get: { viewModel.selectedConnectors.contains(item.id) },
                            set: { on in
                                if on {
                                    viewModel.selectedConnectors.insert(item.id)
                                } else {
                                    viewModel.selectedConnectors.remove(item.id)
                                }
                            }
                        ))
                        .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                        .labelsHidden()
                    } else {
                        Text("Soon")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .opacity(available ? 1 : 0.65)

                if index < marketplace.connectors.count - 1 {
                    Divider()
                        .background(Theme.separator)
                        .padding(.leading, 60)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .padding(.horizontal, 16)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Connectors")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            // Reserved for symmetry; purpose TBD once the desktop server
            // exposes a connector-authorisation flow.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Discovery Toggle

    private var discoveryToggle: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("Connector discovery")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("New connectors added by the desktop server will appear here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $viewModel.connectorDiscoveryEnabled)
                .labelsHidden()
                .tint(Theme.selection)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.surface)
                    .frame(width: 64, height: 64)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("No connectors yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Connect to a desktop server and turn on connector discovery to see them here.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var connectorsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.mcpManager.configuredServers.enumerated()), id: \.element.id) { index, server in
                ConnectorServerRow(
                    server: server,
                    isSelected: server.isEnabled
                ) {
                    state.mcpManager.toggleServer(server.id)
                }

                if index < state.mcpManager.configuredServers.count - 1 {
                    Divider()
                        .background(Theme.separator)
                        .padding(.leading, 60)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

/// Individual connector row, backed by a real `MCPServer` from the desktop-synced
/// list. The trailing switch toggles its enabled state.
struct ConnectorServerRow: View {
    let server: MCPServer
    let isSelected: Bool
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName(for: server))
                .font(.system(size: 20))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 32, height: 32)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                if !server.description.isEmpty {
                    Text(server.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onTap() }
            ))
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func iconName(for server: MCPServer) -> String {
        // Heuristic icon picks — overridable per-server via env later.
        let lower = server.name.lowercased()
        if lower.contains("gmail") || lower.contains("mail") { return "envelope" }
        if lower.contains("drive") { return "folder" }
        if lower.contains("calendar") { return "calendar" }
        if lower.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if lower.contains("slack") { return "bubble.left.and.bubble.right" }
        if lower.contains("figma") { return "paintpalette" }
        if lower.contains("postgres") || lower.contains("sql") { return "cylinder" }
        return "puzzlepiece"
    }
}

#Preview {
    ConnectorsView(viewModel: ChatViewModel())
        .environmentObject(AppState(secrets: KeychainSecretStore()))
}
