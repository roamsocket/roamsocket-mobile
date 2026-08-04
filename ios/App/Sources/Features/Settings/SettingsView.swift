import SwiftUI
import MobileAICore

/// Settings: provider API keys, GitHub linking (Device Flow or PAT), and
/// desktop-server pairing.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showSkills = false
    @State private var showMCP = false

    var body: some View {
        NavigationStack {
            Form {
                providerKeysSection
                gitHubSection
                serverSection
                skillsSection
                mcpSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSkills) {
            InstalledSkillsView()
        }
        .sheet(isPresented: $showMCP) {
            MCPManagerView()
        }
    }

    // MARK: Provider keys

    private var providerKeysSection: some View {
        Section("Provider API keys") {
            ForEach(ProviderID.allCases) { provider in
                ProviderKeyRow(provider: provider)
            }
            Button("Refresh models") {
                Task { await state.refreshModels() }
            }
        }
    }

    // MARK: GitHub

    private var gitHubSection: some View {
        Section("GitHub") {
            if let token = state.githubToken, !token.isEmpty {
                HStack {
                    Label("Linked", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Unlink", role: .destructive) { state.githubToken = nil }
                }
            } else {
                NavigationLink("Link GitHub account") { GitHubLinkView() }
            }
            LabeledContent("OAuth client id") {
                TextField("Iv1.xxx", text: $state.githubClientID)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
            }
        }
    }

    // MARK: Server pairing

    private var serverSection: some View {
        Section("Desktop coding server") {
            if let name = state.serverName, state.serverToken != nil {
                HStack {
                    Label("Paired with \(name)", systemImage: "desktopcomputer")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Unpair", role: .destructive) {
                        state.serverToken = nil
                        state.serverName = nil
                    }
                }
            } else {
                NavigationLink("Pair with a server") { ServerPairingView() }
            }
        }
    }

    // MARK: Skills

    private var skillsSection: some View {
        Section("Skills") {
            Button {
                showSkills = true
            } label: {
                HStack {
                    Label("Manage Skills", systemImage: "sparkles")
                    Spacer()
                    let count = state.skillManager.installedSkills.count
                    if count > 0 {
                        Text("\(count) installed")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: MCP

    private var mcpSection: some View {
        Section("MCP Servers") {
            Button {
                showMCP = true
            } label: {
                HStack {
                    Label("Manage MCP Servers", systemImage: "server.rack")
                    Spacer()
                    let count = state.mcpManager.configuredServers.count
                    if count > 0 {
                        Text("\(count) configured")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

private struct ProviderKeyRow: View {
    @EnvironmentObject var state: AppState
    let provider: ProviderID
    @State private var key = ""
    @State private var editing = false

    var body: some View {
        HStack {
            Text(provider.displayName)
            Spacer()
            if editing {
                SecureField("API key", text: $key)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .onSubmit(save)
                Button("Save", action: save)
            } else {
                Text(state.apiKey(for: provider).isEmpty ? "Not set" : "••••••")
                    .foregroundStyle(Theme.textTertiary)
                Button("Edit") {
                    key = state.apiKey(for: provider)
                    editing = true
                }
            }
        }
    }

    private func save() {
        state.setAPIKey(key, for: provider)
        editing = false
    }
}
