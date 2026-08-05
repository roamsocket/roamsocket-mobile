import SwiftUI

/// Connectors list view with discovery toggle. The user's selection (which
/// connector ids are enabled for a chat) is stored on `ChatViewModel`; the
/// actual connector list itself is supplied by the desktop server. If no
/// connectors are available yet, an empty state is shown.
struct ConnectorsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(spacing: 0) {
                            discoveryToggle
                                .padding(.horizontal, 16)
                                .padding(.vertical, 16)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                                .padding(.horizontal, 16)
                                .padding(.top, 16)

                            if viewModel.connectors.isEmpty {
                                emptyState
                                    .padding(.top, 16)
                            } else {
                                connectorsList
                                    .padding(.top, 16)
                            }
                        }
                    }
                }
            }
            .navigationBarHidden(true)
        }
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
            ForEach(Array(viewModel.connectors.enumerated()), id: \.element.id) { index, connector in
                ConnectorRow(
                    connector: connector,
                    isSelected: viewModel.isConnectorSelected(connector),
                    onTap: { viewModel.toggleConnector(connector) }
                )

                if index < viewModel.connectors.count - 1 {
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

/// Individual connector row
struct ConnectorRow: View {
    let connector: Connector
    let isSelected: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: connector.iconName)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))

                Text(connector.name)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Text("\(connector.itemCount)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(minWidth: 28, minHeight: 28)
                    .padding(.horizontal, 8)
                    .background(Theme.selection, in: Capsule())

                Image(systemName: isSelected ? "checkmark" : "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ConnectorsView(viewModel: ChatViewModel())
}
