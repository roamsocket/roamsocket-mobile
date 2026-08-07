import SwiftUI
import AnyProvCore

/// Recovery flow when the Devices row cannot reconnect automatically.
/// Walks the user through Wi‑Fi + desktop-running checks, then offers
/// Bonjour rescan or a manual IP when they confirm the basics are right.
struct DeviceConnectionHelpSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var browser = ServerBrowser()

    @State private var phase: Phase = .checklist
    @State private var manualHost = ""
    @State private var status = ""
    @State private var busy = false

    /// Called when the saved token is rejected and the user must re-pair.
    var onNeedsPairing: () -> Void = {}

    private enum Phase {
        case checklist
        case findServer
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if phase == .checklist {
                        checklistContent
                    } else {
                        findServerContent
                    }
                    if !status.isEmpty {
                        Text(status)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(phase == .checklist ? "Can't connect" : "Find desktop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if manualHost.isEmpty {
                    manualHost = preferredManualHost
                }
            }
            .onDisappear {
                browser.stop()
            }
            .onChange(of: state.desktopReachability) { _, reachability in
                if reachability == .connected {
                    status = "Connected."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.serverName ?? "Desktop")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(state.desktopReachability.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if let message = state.reconnectMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Checklist

    private var checklistContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before we dig further, check these on the phone and desktop:")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)

            checklistRow(
                icon: "wifi",
                title: "Same Wi‑Fi as the desktop",
                detail: "The phone must be on the same network the server is using (not cellular)."
            )
            checklistRow(
                icon: "desktopcomputer",
                title: "Desktop server is running",
                detail: "Open the RoamSocket desktop app or start the companion server and leave it open."
            )
            if let host = state.localEndpoint?.baseURL.host ?? state.serverEndpoint?.baseURL.host {
                checklistRow(
                    icon: "network",
                    title: "Last known address",
                    detail: host
                )
            }

            VStack(spacing: 10) {
                Button {
                    Task { await tryReconnectAgain() }
                } label: {
                    labelRow(
                        title: busy || state.isReconnecting ? "Connecting…" : "Try connecting again",
                        systemImage: "arrow.clockwise",
                        primary: true
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy || state.isReconnecting)

                Button {
                    withAnimation {
                        phase = .findServer
                        status = ""
                        browser.start()
                    }
                } label: {
                    labelRow(
                        title: "I'm on the right Wi‑Fi and it's running",
                        systemImage: "checkmark.circle",
                        primary: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy || state.isReconnecting)

                Button {
                    onNeedsPairing()
                } label: {
                    labelRow(
                        title: "Enter a new pairing code",
                        systemImage: "qrcode.viewfinder",
                        primary: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy || state.isReconnecting)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Find server

    private var findServerContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rescan this network for the desktop, or type its IP if you know it.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)

            // Nearby / rescan
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Nearby servers")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button {
                        rescan()
                    } label: {
                        HStack(spacing: 6) {
                            if browser.isBrowsing {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(browser.isBrowsing ? "Scanning…" : "Rescan")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || state.isReconnecting)
                }

                if browser.servers.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: browser.isBrowsing ? "wifi" : "wifi.slash")
                            .foregroundStyle(Theme.textTertiary)
                        Text(
                            browser.isBrowsing
                                ? "Looking for desktops on this Wi‑Fi…"
                                : "No servers found yet. Tap Rescan, or enter an IP below."
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 8) {
                        ForEach(browser.servers) { server in
                            Button {
                                Task { await connect(to: server.baseURLString) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "desktopcomputer")
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.displayTitle)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(server.displaySubtitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .padding(12)
                                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(busy || state.isReconnecting)
                        }
                    }
                }

                if let err = browser.lastError, !err.isEmpty {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

            // Manual IP
            VStack(alignment: .leading, spacing: 12) {
                Text("Or type the IP")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Example: 192.168.1.20 or http://192.168.1.20:4319")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)

                TextField("http://192.168.1.20:4319", text: $manualHost)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Theme.textPrimary)

                Button {
                    Task { await connect(to: manualHost) }
                } label: {
                    labelRow(
                        title: busy || state.isReconnecting ? "Connecting…" : "Connect to this address",
                        systemImage: "link",
                        primary: true
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy || state.isReconnecting || manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

            Button {
                withAnimation {
                    phase = .checklist
                    browser.stop()
                    status = ""
                }
            } label: {
                Text("Back to checklist")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)

            Button {
                onNeedsPairing()
            } label: {
                Text("Still stuck? Enter a new pairing code")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    // MARK: - Shared UI

    private func checklistRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func labelRow(title: String, systemImage: String, primary: Bool) -> some View {
        HStack(spacing: 10) {
            if !primary {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            if (busy || state.isReconnecting), primary {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.background)
            } else if primary {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(primary ? .center : .leading)
            if !primary {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: primary ? .center : .leading)
        .foregroundStyle(primary ? Theme.background : Theme.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            primary ? Theme.accent : Theme.surfaceElevated,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    // MARK: - Actions

    private var preferredManualHost: String {
        if let local = state.localEndpoint {
            return local.baseURL.absoluteString
        }
        if !state.serverLocalHost.isEmpty {
            return state.serverLocalHost
        }
        if let active = state.serverEndpoint, AppState.connectionPath(for: active) == .local {
            return active.baseURL.absoluteString
        }
        return "http://192.168.1.20:4319"
    }

    private func rescan() {
        status = "Scanning this network…"
        browser.start()
    }

    private func tryReconnectAgain() async {
        // Token already rejected — go straight to re-pair without another probe.
        if state.needsServerRePair {
            status = state.reconnectMessage ?? "Pairing expired — enter a new code from the desktop."
            onNeedsPairing()
            return
        }
        busy = true
        status = "Trying saved addresses…"
        let outcome = await state.attemptServerReconnect()
        busy = false
        handle(outcome: outcome, successMessage: "Connected.")
    }

    private func connect(to rawHost: String) async {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = ServerClient.Endpoint(host: trimmed) else {
            status = "Invalid address. Use something like 192.168.1.20 or http://192.168.1.20:4319."
            return
        }
        busy = true
        status = "Connecting to \(endpoint.baseURL.host ?? trimmed)…"
        manualHost = endpoint.baseURL.absoluteString
        let outcome = await state.reconnectToEndpoint(endpoint)
        busy = false
        handle(outcome: outcome, successMessage: "Connected to \(endpoint.baseURL.host ?? trimmed).")
    }

    private func handle(outcome: AppState.ServerReconnectOutcome, successMessage: String) {
        switch outcome {
        case .connected:
            status = successMessage
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                dismiss()
            }
        case .needsRePair:
            status = state.reconnectMessage ?? "Pairing expired — enter a new code from the desktop."
            onNeedsPairing()
        case .unreachable:
            status = state.reconnectMessage
                ?? "Still can't reach the desktop. Confirm Wi‑Fi, that the server is running, or try another address."
        case .unpaired:
            status = "Not paired. Enter a pairing code from the desktop."
            onNeedsPairing()
        }
    }
}
