import SwiftUI
import AnyProvCore

/// Link a GitHub account via Device Flow (no secret) or a pasted PAT.
struct GitHubLinkView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var deviceCode: DeviceCode?
    @State private var status = ""
    @State private var busy = false
    @State private var pat = ""

    var body: some View {
        Form {
            Section("Device Flow") {
                if let code = deviceCode {
                    LabeledContent("Enter this code", value: code.userCode)
                        .font(.system(.body, design: .monospaced))
                    Button("Open github.com/login/device") {
                        openURL(URL(string: code.verificationURI)!)
                    }
                    if busy { ProgressView() }
                    if !status.isEmpty {
                        Text(status).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Button("Sign in with GitHub", action: startDeviceFlow)
                        .disabled(state.githubClientID.isEmpty)
                    if state.githubClientID.isEmpty {
                        Text("Set an OAuth client id in Settings first, or use a token below.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            Section {
                SecureField("ghp_…", text: $pat)
                    .textInputAutocapitalization(.never)
                Button("Generate token on GitHub") {
                    openURL(Self.generateTokenURL)
                }
                Button("Save token") {
                    state.githubToken = pat
                    dismiss()
                }
                .disabled(pat.isEmpty)
            } header: {
                Text("Personal access token")
            } footer: {
                Text("Opens GitHub’s classic token page. Select all scopes, generate the token, then paste it above.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Link GitHub")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Classic PAT create page with all common scopes pre-checked.
    /// User should still confirm every scope is selected before generating.
    private static let generateTokenURL: URL = {
        var components = URLComponents(string: "https://github.com/settings/tokens/new")!
        components.queryItems = [
            URLQueryItem(name: "description", value: "CodeSocket"),
            URLQueryItem(
                name: "scopes",
                value: [
                    "repo",
                    "workflow",
                    "write:packages",
                    "delete:packages",
                    "admin:org",
                    "admin:public_key",
                    "admin:repo_hook",
                    "admin:org_hook",
                    "gist",
                    "notifications",
                    "user",
                    "delete_repo",
                    "write:discussion",
                    "project",
                    "admin:enterprise",
                    "admin:gpg_key",
                    "admin:ssh_signing_key",
                    "codespace",
                    "copilot",
                ].joined(separator: ",")
            ),
        ]
        return components.url!
    }()

    private func startDeviceFlow() {
        let client = GitHubClient(clientID: state.githubClientID)
        busy = true
        status = "Requesting code…"
        Task {
            do {
                let code = try await client.requestDeviceCode()
                deviceCode = code
                status = "Waiting for you to authorize…"
                let token = try await client.awaitToken(code)
                state.githubToken = token
                busy = false
                dismiss()
            } catch {
                status = error.localizedDescription
                busy = false
            }
        }
    }
}
