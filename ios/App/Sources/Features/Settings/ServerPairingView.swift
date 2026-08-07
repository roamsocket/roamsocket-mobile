import SwiftUI
import AnyProvCore
#if canImport(UIKit)
import UIKit
#endif

/// Pair with a running desktop server by picking a LAN-discovered host or
/// entering its address and pairing code (shown in the server console / QR).
struct ServerPairingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var browser = ServerBrowser()

    @State private var host = "http://localhost:4319"
    @State private var code = ""
    @State private var status = ""
    @State private var busy = false
    @State private var showScanner = false

    var body: some View {
        Form {
            Section {
                Button {
                    showScanner = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scan desktop QR")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Scan the code shown in the desktop app or terminal")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Quick pair")
            }

            Section {
                if browser.servers.isEmpty {
                    HStack(spacing: 10) {
                        if browser.isBrowsing {
                            ProgressView()
                        } else {
                            Image(systemName: "wifi.slash")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(browser.isBrowsing ? "Looking for servers on this network…" : "Not browsing")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Start the desktop app on the same Wi‑Fi. You can still enter an address manually below.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(browser.servers) { server in
                        Button {
                            host = server.baseURLString
                            status = "Selected \(server.displayTitle)."
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.displayTitle)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(server.displaySubtitle)
                                        .font(.footnote)
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if host.trimmingCharacters(in: .whitespacesAndNewlines) == server.baseURLString {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let err = browser.lastError, !err.isEmpty {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Nearby servers")
            } footer: {
                Text("Desktops advertise themselves with Bonjour (_roamsocket._tcp). Pull to refresh if a machine just started.")
            }

            Section("Server address") {
                TextField("http://192.168.1.20:4319", text: $host)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
            }
            Section("Pairing code") {
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                Button("Pair", action: pair)
                    .disabled(busy || code.isEmpty || host.isEmpty)
                if busy { ProgressView() }
                if !status.isEmpty {
                    Text(status).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            if state.serverToken != nil {
                Section {
                    Button("Reconnect now") {
                        Task {
                            busy = true
                            await state.attemptServerReconnect()
                            status = state.reconnectMessage ?? "Connected."
                            busy = false
                        }
                    }
                    .disabled(busy)
                    Button("Forget this server", role: .destructive) {
                        state.clearPairing()
                        status = "Cleared."
                    }
                }
            }
            Section {
                Text("Use a nearby server or the LAN address while at home, or the public tunnel URL from desktop Settings → Remote access when away. The app auto-reconnects on launch.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Pair server")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            browser.start()
        }
        .sheet(isPresented: $showScanner) {
            PairQRScannerView { scannedHost, scannedCode in
                if !scannedHost.isEmpty {
                    host = scannedHost
                }
                if !scannedCode.isEmpty {
                    code = scannedCode
                }
                status = scannedHost.isEmpty
                    ? "Code scanned. Confirm the server address, then Pair."
                    : "QR scanned. Review and tap Pair."
            }
        }
        .onAppear {
            if !state.serverHost.isEmpty {
                host = state.serverHost
            }
            browser.start()
        }
        .onDisappear {
            browser.stop()
        }
    }

    private func pair() {
        guard let endpoint = ServerClient.Endpoint(host: host) else {
            status = "Invalid address."
            return
        }
        busy = true
        status = "Pairing…"
        Task {
            do {
                let response = try await state.serverClient.pair(
                    endpoint: endpoint,
                    code: code,
                    deviceName: deviceName())
                // Prefer an already-running public URL from the pair response.
                let initialURL = response.publicUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let initialURL, !initialURL.isEmpty,
                   let publicEndpoint = ServerClient.Endpoint(host: initialURL) {
                    state.savePairing(
                        endpoint: publicEndpoint,
                        token: response.token,
                        serverName: response.serverName
                    )
                    status = "Paired via secure tunnel."
                    busy = false
                    dismiss()
                    return
                }

                state.savePairing(
                    endpoint: endpoint,
                    token: response.token,
                    serverName: response.serverName
                )
                // Desktop starts Cloudflare/ngrok/…; wait and switch the phone over.
                status = "Paired. Opening secure tunnel for off-network access…"
                let upgrade = await state.upgradePairingToTunnel(timeoutSeconds: 50)
                status = upgrade
                busy = false
                // Always dismiss after a successful pair — LAN still works if tunnel failed.
                dismiss()
            } catch {
                status = error.localizedDescription
                busy = false
            }
        }
    }

    private func deviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return "Device"
        #endif
    }
}
