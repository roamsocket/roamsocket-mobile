import AnyProvCore
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// SwiftUI sheet for the iOS app's "Pair server → Auto-setup over SSH" flow.
///
/// User enters `user@host:port`, picks auth (password or pasted ED25519
/// private key), and taps *Start setup*. The view drives an
/// `SSHProvisioner` actor and surfaces progress; on success it finishes
/// the pair via the existing `ServerClient.pair(...)` + `AppState.savePairing(...)`
/// path so the rest of the app sees the same "paired" state whether the
/// user did this via QR scan, LAN entry, or SSH bootstrap.
struct SSHAutoSetupView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authKind: AuthKind = .password
    @State private var password = ""
    @State private var privateKey = ""
    @State private var installCommand = "npm i -g @roamsocket/server"

    @State private var phase: Phase = .form
    @State private var progressLine: String = ""
    @State private var error: String?
    @State private var result: SSHProvisionResult?

    enum AuthKind: String, CaseIterable, Identifiable {
        case password = "Password"
        case privateKey = "Private key"
        var id: String {
            rawValue
        }
    }

    enum Phase: Equatable {
        case form
        case running
        case pairing(code: String, endpoint: ServerClient.Endpoint)
        case done(pairingCode: String, serverName: String)
    }

    var body: some View {
        Form {
            connectionSection
            authSection
            installSection
            if !progressLine.isEmpty {
                Section("Status") { statusRow }
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if let result {
                Section("Result") { resultSummary(result) }
            }
            actionSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Auto-setup over SSH")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .disabled(phase == .running)
            }
        }
        .interactiveDismissDisabled(phase == .running)
    }

    // MARK: - sections

    private var connectionSection: some View {
        Section {
            TextField("host or IP", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(phase == .running)
            TextField("22", text: $port)
                .keyboardType(.numberPad)
                .disabled(phase == .running)
            TextField("username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(phase == .running)
        } header: {
            Text("Remote host")
        } footer: {
            Text("Point at any machine that has (or can install) Node.js 20+. A cloud VM, your Mac over LAN, or a Raspberry Pi.")
        }
    }

    private var authSection: some View {
        Section {
            Picker("Method", selection: $authKind) {
                ForEach(AuthKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(phase == .running)
            switch authKind {
            case .password:
                SecureField("password", text: $password)
                    .disabled(phase == .running)
            case .privateKey:
                TextEditor(text: $privateKey)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 120)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(phase == .running)
            }
        } header: {
            Text("Authentication")
        } footer: {
            switch authKind {
            case .password:
                Text("The remote user's password. Stored only in memory for this setup session.")
            case .privateKey:
                Text("Paste the contents of ~/.ssh/id_ed25519 (unencrypted — strip the passphrase with `ssh-keygen -p -m PEM` first).")
            }
        }
    }

    private var installSection: some View {
        Section {
            TextField("install command", text: $installCommand)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(phase == .running)
        } header: {
            Text("Install")
        } footer: {
            Text("Defaults to a global npm install of @roamsocket/server. Customize if you publish a fork or want to install from a private registry.")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            if phase == .running {
                ProgressView()
            } else if case let .done(_, name) = phase {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.selection)
            } else if let _ = error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(progressLine)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
    }

    private func resultSummary(_ r: SSHProvisionResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Pairing code", r.pairingCode)
            if let url = r.publicURL {
                row("Tunnel", url)
            } else if let lan = r.lanURL {
                row("LAN", lan)
            }
            if let name = r.serverName {
                row("Server", name)
            }
            if let v = r.serverVersion {
                row("Version", v)
            }
            if !r.installLog.isEmpty {
                DisclosureGroup("Install log") {
                    Text(r.installLog)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        }
    }

    private var actionSection: some View {
        Section {
            switch phase {
            case .form:
                Button {
                    startSetup()
                } label: {
                    HStack {
                        Image(systemName: "bolt.horizontal.circle.fill")
                        Text("Start setup")
                    }
                }
                .disabled(!isFormValid)
            case .running:
                Button(role: .destructive) {
                    cancelSetup()
                } label: {
                    HStack {
                        Image(systemName: "stop.circle")
                        Text("Cancel")
                    }
                }
            case let .pairing(code, endpoint):
                Button {
                    finishPairing(code: code, endpoint: endpoint)
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text("Finish pairing")
                    }
                }
            case let .done(code, name):
                Button {
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                        Text("Paired · \(name) · \(code)")
                    }
                }
            }
        }
    }

    // MARK: - actions

    private var isFormValid: Bool {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let portInt = Int(port),
              (1 ..< 65536).contains(portInt),
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        switch authKind {
        case .password: return !password.isEmpty
        case .privateKey: return privateKey.contains("BEGIN")
        }
    }

    private var provisionerTask: Task<Void, Never>? = nil
    @State private var taskHandle: Task<Void, Never>?

    private func startSetup() {
        guard let portInt = Int(port) else { return }
        let auth: SSHAuth
        switch authKind {
        case .password: auth = .password(password)
        case .privateKey: auth = .privateKey(pem: privateKey, passphrase: nil)
        }
        let config = SSHProvisionConfig(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: portInt,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            auth: auth,
            installCommand: installCommand
        )

        phase = .running
        progressLine = "Starting…"
        error = nil
        result = nil

        taskHandle?.cancel()
        taskHandle = Task {
            let provisioner = SSHProvisioner()
            do {
                let r = try await provisioner.provision(config) { line in
                    Task { @MainActor in
                        progressLine = line
                    }
                }
                await MainActor.run {
                    result = r
                    let endpoint = preferredEndpoint(from: r)
                    phase = .pairing(code: r.pairingCode, endpoint: endpoint)
                }
            } catch {
                await MainActor.run {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    phase = .form
                }
            }
        }
    }

    private func cancelSetup() {
        taskHandle?.cancel()
        taskHandle = nil
        phase = .form
        progressLine = ""
    }

    /// Prefer the public tunnel URL when the server handed us one — it's
    /// reachable from anywhere. Otherwise fall back to the LAN URL so
    /// users on the same network can still pair.
    private func preferredEndpoint(from r: SSHProvisionResult) -> ServerClient.Endpoint {
        let candidate = (r.publicURL?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? r.lanURL
            ?? ""
        // Strip trailing slash + ensure scheme; Endpoint handles defaults.
        let cleaned = candidate.hasSuffix("/")
            ? String(candidate.dropLast())
            : candidate
        return ServerClient.Endpoint(host: cleaned)
            ?? ServerClient.Endpoint(host: r.lanURL ?? "")
            ?? ServerClient.Endpoint(host: "http://localhost:4319")!
    }

    private func finishPairing(code: String, endpoint: ServerClient.Endpoint) {
        Task {
            do {
                let response = try await state.serverClient.pair(
                    endpoint: endpoint,
                    code: code,
                    deviceName: UIDevice.current.name
                )
                await MainActor.run {
                    state.savePairing(
                        endpoint: endpoint,
                        token: response.token,
                        serverName: response.serverName
                    )
                    phase = .done(pairingCode: response.serverName, serverName: response.serverName)
                    progressLine = "Paired."
                }
            } catch {
                await MainActor.run {
                    self.error = (error as? LocalizedError)?.errorDescription
                        ?? "Pair failed: \(error.localizedDescription)"
                    phase = .pairing(code: code, endpoint: endpoint)
                }
            }
        }
    }
}
