import SwiftUI
import MobileAICore

/// Settings sheet mirroring the iOS Claude app layout. Every row is wired to
/// a real configuration destination — the bogus "Profile / Billing / Usage /
/// Notifications / Privacy / Shared links / Capabilities / Connectors /
/// Permissions / Voice" placeholders are gone. The full legacy form lives
/// behind "Advanced settings".
struct ClaudeSettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let onOpenLegacySettings: () -> Void

    @State private var showGitHubLink = false
    @State private var showServerPair = false
    @State private var showSkills = false
    @State private var showMCP = false
    @State private var showAbout = false
    @State private var showProviderKeys = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 16) {
                        accountSection
                        codingSection
                        skillsSection
                        mcpSection
                        advancedButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showGitHubLink) {
            NavigationStack { GitHubLinkView() }
        }
        .sheet(isPresented: $showServerPair) {
            NavigationStack { ServerPairingView() }
        }
        .sheet(isPresented: $showSkills) {
            InstalledSkillsView()
        }
        .sheet(isPresented: $showMCP) {
            MCPManagerView()
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
        .sheet(isPresented: $showProviderKeys) {
            ProviderKeysView()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Settings")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button(action: { showAbout = true }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Account

    /// GitHub link status + provider API keys. Replaces the old fake
    /// "Profile / Billing / Usage / Notifications / Privacy / Shared links"
    /// block — those were dead-ended menu items.
    private var accountSection: some View {
        settingsCard(header: "Account") {
            Button {
                showGitHubLink = true
            } label: {
                row(
                    systemImage: "link",
                    title: "GitHub",
                    trailing: githubStatus
                )
            }
            .buttonStyle(.plain)

            Divider().background(Theme.separator)

            Button {
                showProviderKeys = true
            } label: {
                row(
                    systemImage: "key.fill",
                    title: "Provider API keys",
                    trailing: providerKeysStatus
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var githubStatus: String {
        state.githubToken?.isEmpty == false ? "Linked" : "Not linked"
    }

    private var providerKeysStatus: String {
        let count = ProviderID.allCases.filter { !state.apiKey(for: $0).isEmpty }.count
        let total = ProviderID.allCases.count
        return count == 0 ? "Not set" : "\(count)/\(total)"
    }

    // MARK: - Coding

    /// Desktop server pairing. Replaces the old fake "Capabilities /
    /// Connectors / Permissions / Voice" block — those were dead-ended.
    private var codingSection: some View {
        settingsCard(header: "Coding") {
            Button {
                showServerPair = true
            } label: {
                row(
                    systemImage: "desktopcomputer",
                    title: "Desktop server",
                    trailing: serverStatus
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var serverStatus: String {
        if let name = state.serverName, !name.isEmpty { return "Paired · \(name)" }
        return "Not paired"
    }

    // MARK: - Skills

    private var skillsSection: some View {
        settingsCard(header: "Skills") {
            Button {
                showSkills = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 28)
                    Text("Manage skills")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    let count = state.skillManager.installedSkills.count
                    if count > 0 {
                        Text("\(count) installed")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - MCP

    private var mcpSection: some View {
        settingsCard(header: "MCP Servers") {
            Button {
                showMCP = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 28)
                    Text("Manage MCP servers")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    let count = state.mcpManager.configuredServers.count
                    if count > 0 {
                        Text("\(count) configured")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Advanced

    private var advancedButton: some View {
        Button(action: {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                onOpenLegacySettings()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "gear")
                Text("Advanced settings")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingsCard<Content: View>(header: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(header)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    @ViewBuilder
    private func row(systemImage: String, title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 28)
            Text(title)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - Provider Keys sheet

/// Quick view of provider API keys (one sheet to look at and edit them from
/// the Claude-style settings). The legacy `SettingsView` is the full form;
/// this is the abbreviated entry.
private struct ProviderKeysView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider API keys") {
                    ForEach(ProviderID.allCases) { provider in
                        ProviderKeyRow(provider: provider)
                    }
                }
                Section {
                    Button("Refresh models") {
                        Task { await state.refreshModels() }
                    }
                }
                Section {
                    Text("Keys are stored in the iOS Keychain. Tap a row to edit.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Provider API keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
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
                    .foregroundStyle(Theme.textSecondary)
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

// MARK: - About sheet

private struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Code Mobile AI")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Version \(appVersion)")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("An open-source iOS client for Claude Code and other providers, paired with a desktop coding server.")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                if let url = URL(string: "https://github.com/kind365/code-mobile-ai") {
                                    openURL(url)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.forward.app")
                                    Text("Project repository")
                                }
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.selection)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ClaudeSettingsView(onOpenLegacySettings: {})
        .environmentObject(AppState(secrets: KeychainSecretStore()))
}
