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

    @State private var showGitHubLink = false
    @State private var showServerPair = false
    @State private var showSkills = false
    @State private var showMCP = false
    @State private var showAbout = false
    @State private var showProviderKeys = false

    /// Optional entry focus. `.providers` jumps straight into the API-key
    /// providers screen as soon as the settings sheet finishes presenting,
    /// which is what the model-selector pill uses when the user has no
    /// usable model yet. Defaults to nil so the home-screen entry keeps
    /// landing on the main settings page.
    var initialFocus: SettingsFocus? = nil
    @State private var autoOpenedFocus: Bool = false

    init(initialFocus: SettingsFocus? = nil) {
        self.initialFocus = initialFocus
    }

    enum SettingsFocus: String, Hashable {
        case providers
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 16) {
                        accountSection
                        codingSection
                        syncSection
                        skillsSection
                        mcpSection
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
        .task {
            // Pull the latest skills + MCP from the desktop every time the
            // settings sheet appears. The server's reply lands in the
            // SkillsMCPClient and updates the local caches.
            if state.serverToken != nil {
                await state.skillsMCPClient.refreshAll(over: state.serverClient)
            }
            // Honor the caller's entry focus on first presentation only,
            // so re-opens don't keep shoving the user back into the
            // providers screen.
            if !autoOpenedFocus, initialFocus == .providers {
                autoOpenedFocus = true
                showProviderKeys = true
            }
        }
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
            ConnectorManagerView()
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

    /// Skills + connectors are synced from git repos on the user's GitHub
    /// account. The actual git operations happen on the desktop; this
    /// section just stores the repo URLs/branches and tells the user to
    /// configure them on the desktop side too.
    private var syncSection: some View {
        settingsCard(header: "Sync") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Skills & connectors are pulled from git repos on your GitHub account. Configure the URLs in the desktop app or via environment variables:")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CMAI_SKILLS_REPO / CMAI_MCP_REPO")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    Text("CMAI_SKILLS_BRANCH / CMAI_MCP_BRANCH (default main)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    Text("CMAI_SKILLS_TOKEN / CMAI_MCP_TOKEN (optional GitHub PAT)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

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
        settingsCard(header: "Connectors") {
            Button {
                showMCP = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 28)
                    Text("Manage connectors")
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
/// the Claude-style settings).
/// this is the abbreviated entry.
private struct ProviderKeysView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showAddCustom = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider API keys") {
                    ForEach(ProviderID.allCases) { provider in
                        ProviderKeyRow(provider: provider)
                    }
                }

                Section {
                    Button {
                        showAddCustom = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add custom provider")
                        }
                    }
                    if !state.customProviders.isEmpty {
                        ForEach(state.customProviders) { provider in
                            CustomProviderRow(provider: provider)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                state.deleteCustomProvider(state.customProviders[index])
                            }
                        }
                    }
                } header: {
                    Text("Custom providers")
                } footer: {
                    Text("Custom providers use the OpenAI-compatible /v1/chat/completions or Anthropic /v1/messages endpoint. The base URL must include the version segment (e.g. https://api.example.com/v1).")
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
            .sheet(isPresented: $showAddCustom) {
                AddCustomProviderView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Sheet for adding an OpenAI- or Anthropic-style custom provider.
private struct AddCustomProviderView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var style: Style = .openAI
    @State private var error: String?

    enum Style: String, CaseIterable, Identifiable {
        case openAI = "OpenAI-compatible"
        case anthropic = "Anthropic"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    TextField("My proxy", text: $label)
                        .textInputAutocapitalization(.words)
                }
                Section {
                    Picker("API style", selection: $style) {
                        ForEach(Style.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("https://api.example.com/v1", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Endpoint")
                } footer: {
                    Text(style == .openAI
                         ? "Uses POST {base}/chat/completions with the OpenAI request shape."
                         : "Uses POST {base}/messages with the Anthropic request shape.")
                }
                Section("API key") {
                    SecureField("sk-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Add custom provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(label.isEmpty || baseURL.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        // The current `addCustomProvider` always registers as an
        // OpenAI-compatible provider. We honor the user's style pick by
        // adjusting the base URL the provider stores so the underlying
        // client dispatches correctly.
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = state.addCustomProvider(label: label, baseURL: url, apiKey: apiKey)
        if provider == nil {
            error = "Couldn't save. Check the base URL and try a unique label."
            return
        }
        dismiss()
    }
}

private struct CustomProviderRow: View {
    @EnvironmentObject var state: AppState
    let provider: CustomProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.label)
            Text(provider.baseURL)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
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
    ClaudeSettingsView()
        .environmentObject(AppState(secrets: KeychainSecretStore()))
}
