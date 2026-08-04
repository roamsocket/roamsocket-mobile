import SwiftUI
import MobileAICore

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

            Section("Personal access token") {
                SecureField("ghp_…", text: $pat)
                    .textInputAutocapitalization(.never)
                Button("Save token") {
                    state.githubToken = pat
                    dismiss()
                }
                .disabled(pat.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Link GitHub")
        .navigationBarTitleDisplayMode(.inline)
    }

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
