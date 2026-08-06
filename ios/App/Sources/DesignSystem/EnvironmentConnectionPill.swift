import SwiftUI
import AnyProvCore

/// Centered status strip for an active **coding session**: environment +
/// Local/Tunnel path. Tapping the connection chip chooses Smart / Always local
/// / Always tunnel (no IP shown).
struct EnvironmentConnectionPill: View {
    @EnvironmentObject var state: AppState

    /// Session environment (frozen at session start). Falls back to global
    /// selection only if the session didn't carry one.
    var environment: EnvironmentConfig? = nil

    @State private var showConnectionPicker = false

    private var envName: String {
        let name = (environment ?? state.selectedEnvironment)?.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        return "No environment"
    }

    private var path: AppState.ServerConnectionPath {
        if let endpoint = state.serverEndpoint {
            return AppState.connectionPath(for: endpoint)
        }
        return .offline
    }

    private var hasEnvironment: Bool {
        (environment ?? state.selectedEnvironment) != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            envChip
            connectionChip
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(envName), \(path.label), \(state.connectionPreference.title)")
        .sheet(isPresented: $showConnectionPicker) {
            ConnectionPreferenceSheet()
                .environmentObject(state)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var envChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "cloud")
                .font(.system(size: 11, weight: .semibold))
            Text(envName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(hasEnvironment ? Theme.textPrimary : Theme.textTertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    private var connectionChip: some View {
        Button {
            showConnectionPicker = true
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Image(systemName: path.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(path.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Change connection mode")
    }

    private var statusColor: Color {
        switch state.desktopReachability {
        case .connected: return Color.green.opacity(0.9)
        case .connecting: return Color.orange
        case .unreachable: return Color.red.opacity(0.9)
        case .unpaired: return Theme.textTertiary
        }
    }
}

// MARK: - Connection preference sheet

private struct ConnectionPreferenceSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var applying = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("How should this device reach your desktop?")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                VStack(spacing: 0) {
                    ForEach(AppState.ServerConnectionPreference.allCases) { pref in
                        preferenceRow(pref)
                        if pref != AppState.ServerConnectionPreference.allCases.last {
                            Divider().overlay(Theme.separator)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)

                pathFootnote
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background)
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if applying {
                    ProgressView()
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func preferenceRow(_ pref: AppState.ServerConnectionPreference) -> some View {
        let selected = state.connectionPreference == pref
        return Button {
            guard state.connectionPreference != pref else {
                dismiss()
                return
            }
            applying = true
            Task {
                // Awaits tunnel open when switching to Always tunnel with no URL yet.
                await state.setConnectionPreference(pref)
                applying = false
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: pref.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pref.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(pref.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(applying)
    }

    private var pathFootnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDot)
                    .frame(width: 6, height: 6)
                Text("Currently: \(state.serverConnectionPath.label)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            if state.serverConnectionPath != .offline {
                Text(activeHostHint)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
            if let msg = state.reconnectMessage, !msg.isEmpty {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var statusDot: Color {
        switch state.desktopReachability {
        case .connected: return .green
        case .connecting: return .orange
        case .unreachable: return .red
        case .unpaired: return Theme.textTertiary
        }
    }

    private var activeHostHint: String {
        state.serverEndpoint?.baseURL.host ?? "—"
    }
}
