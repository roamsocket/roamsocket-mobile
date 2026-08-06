import SwiftUI
import AnyProvCore

/// App settings sheet. Every row is wired to a real configuration destination.
/// The full legacy form lives behind "Advanced settings".
struct AppSettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showGitHubLink = false
    @State private var showServerPair = false
    @State private var showSkills = false
    @State private var showMCP = false
    @State private var showAbout = false
    @State private var showProviderKeys = false
    @State private var showLocalMetal = false
    @State private var syncInFlight = false
    @State private var syncMessage: String?
    @State private var syncError: String?
    @State private var pendingPullSnapshot: AppSettingsSnapshot?

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
                        appearanceSection
                        chatSection
                        codingSection
                        settingsBackupSection
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
        .sheet(isPresented: $showLocalMetal) {
            LocalMetalSettingsView()
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

            Divider().background(Theme.separator)

            Button {
                showLocalMetal = true
            } label: {
                row(
                    systemImage: "cpu",
                    title: "Manage models (Metal)",
                    trailing: "Chat only"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var githubStatus: String {
        state.githubToken?.isEmpty == false ? "Linked" : "Not linked"
    }

    /// Built-in providers with a stored key, plus every custom provider
    /// (custom hosts count even when the key is blank — Ollama-style).
    private var providerKeysStatus: String {
        let builtIn = ProviderID.allBuiltInCases
            .filter { $0.requiresAPIKey && !state.apiKey(for: $0).isEmpty }
            .count
        let count = builtIn + state.customProviders.count
        if count == 0 { return "Add +" }
        return count == 1 ? "1 provider" : "\(count) providers"
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

            Divider().background(Theme.separator)

            VStack(alignment: .leading, spacing: 6) {
                Text("Branch prefix")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("Each coding session gets its own branch: \(previewBranchExample)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("apc", text: $state.codeBranchPrefix)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)

            if let msg = state.reconnectMessage, !msg.isEmpty {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    private var previewBranchExample: String {
        let p = state.codeBranchPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = p.isEmpty ? "apc" : p
        return "\(prefix)/your-task-a1b2c3d4"
    }

    private var serverStatus: String {
        if state.isReconnecting { return "Reconnecting…" }
        if let name = state.serverName, !name.isEmpty { return "Paired · \(name)" }
        if state.serverToken != nil { return "Paired" }
        return "Not paired"
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        settingsCard(header: "Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                ThemeSegmentedControl(
                    options: AppAppearance.allCases.map { ($0, $0.title) },
                    selection: appearanceBinding
                )
                .accessibilityLabel("Appearance")

                Text(state.appearance.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { state.appearance },
            set: { state.appearance = $0 }
        )
    }

    // MARK: - Chat (thinking display)

    private var chatSection: some View {
        settingsCard(header: "Chat") {
            ToggleRow(
                systemImage: "brain.head.profile",
                title: "Always expand thinking",
                subtitle: "Show full reasoning under the summary row (tap still opens Thought process).",
                iconColor: Theme.accent,
                isOn: $state.alwaysExpandThinking
            )
        }
    }

    // MARK: - Settings backup

    /// GitHub-backed settings sync. The app auto-creates
    /// `anyprov-code-settings` under the user's account on the first push.
    private var settingsBackupSection: some View {
        settingsCard(header: "Settings backup") {
            VStack(alignment: .leading, spacing: 12) {
                Text(settingsBackupBlurb)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                Button(action: pushSettings) {
                    HStack(spacing: 10) {
                        if syncInFlight {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up.doc.on.clipboard")
                        }
                        Text(syncButtonTitle)
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.textPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(syncInFlight)
                .padding(.horizontal, 16)

                if let syncMessage {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 16)
                }
                if let syncError {
                    Text(syncError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }

                Divider().background(Theme.separator)
                Button {
                    pullSettings()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.doc")
                        Text("Restore from GitHub")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(syncInFlight)
            }
            .padding(.vertical, 12)
        }
        .alert(
            "Apply settings from GitHub?",
            isPresented: Binding(
                get: { pendingPullSnapshot != nil },
                set: { if !$0 { pendingPullSnapshot = nil } }
            ),
            presenting: pendingPullSnapshot
        ) { _ in
            Button("Apply", role: .destructive) {
                if let snap = pendingPullSnapshot {
                    state.applySnapshot(snap)
                    syncMessage = "Restored from GitHub."
                    pendingPullSnapshot = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingPullSnapshot = nil }
        } message: { snap in
            Text("GitHub snapshot has \(snap.environments.count) environment(s), \(snap.customProviders.count) custom provider(s), and \(snap.modelAliases.count) model alias(es).")
        }
    }

    private var settingsBackupBlurb: String {
        if let repo = state.settingsSyncRepoFullName {
            return "Settings are stored in \(repo). Add a new device and restore from GitHub to get the same environments, custom providers, and model aliases."
        }
        return "We'll create a private \(SettingsSync.repoName) repo in your account and push your settings there."
    }

    private var syncButtonTitle: String {
        state.settingsSyncRepoFullName == nil ? "Sync to GitHub" : "Push settings"
    }

    private func pushSettings() {
        guard let token = state.githubToken, !token.isEmpty else {
            syncError = nil
            showGitHubLink = true
            return
        }
        syncInFlight = true
        syncError = nil
        syncMessage = nil
        Task {
            do {
                let repo = try await state.settingsSync.ensureRepo(token: token)
                state.settingsSyncRepoFullName = repo.fullName
                let snapshot = state.snapshotForSync()
                try await state.settingsSync.push(
                    snapshot: snapshot,
                    token: token,
                    repoFullName: repo.fullName
                )
                syncMessage = "Pushed to \(repo.fullName)."
            } catch {
                syncError = error.localizedDescription
            }
            syncInFlight = false
        }
    }

    private func pullSettings() {
        guard let token = state.githubToken, !token.isEmpty else {
            syncError = nil
            showGitHubLink = true
            return
        }
        syncInFlight = true
        syncError = nil
        syncMessage = nil
        Task {
            do {
                let repo = try await state.settingsSync.ensureRepo(token: token)
                state.settingsSyncRepoFullName = repo.fullName
                if let snap = try await state.settingsSync.pull(
                    token: token,
                    repoFullName: repo.fullName
                ) {
                    pendingPullSnapshot = snap
                } else {
                    syncMessage = "No settings.json found in \(repo.fullName) yet."
                }
            } catch {
                syncError = error.localizedDescription
            }
            syncInFlight = false
        }
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
                    Text("APC_SKILLS_REPO / APC_MCP_REPO")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    Text("APC_SKILLS_BRANCH / APC_MCP_BRANCH (default main)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    Text("APC_SKILLS_TOKEN / APC_MCP_TOKEN (optional GitHub PAT)")
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
/// app settings).
/// this is the abbreviated entry.
private struct ProviderKeysView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showAddCustom = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider API keys") {
                    ForEach(ProviderID.allCases.filter(\.requiresAPIKey)) { provider in
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
                    Text("Add Ollama, LiteLLM, OpenRouter proxies, or any OpenAI-compatible / Anthropic-compatible host. Pick the endpoint type, set the base URL (include /v1), and store this provider’s own API key — do not put it under OpenAI.")
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
    }
}

/// Sheet for adding an OpenAI- or Anthropic-style custom provider.
private struct AddCustomProviderView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var style: CustomProviderStyle = .openAI
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    TextField("My proxy / Ollama", text: $label)
                        .textInputAutocapitalization(.words)
                }
                Section {
                    Picker("Endpoint type", selection: $style) {
                        ForEach(CustomProviderStyle.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    TextField(style == .openAI
                             ? "http://localhost:11434/v1"
                             : "https://api.example.com/v1",
                             text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Endpoint")
                } footer: {
                    Text(style.detail + "\nBase URL must include the version segment (e.g. …/v1), not the full /chat/completions or /messages path.")
                }
                Section {
                    SecureField(style == .anthropic ? "sk-ant-…" : "sk-… / ollama (optional)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("API key for this provider")
                } footer: {
                    Text("Stored under this custom provider only — not the built-in OpenAI field.")
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
    }

    private func save() {
        let provider = state.addCustomProvider(
            label: label,
            baseURL: baseURL,
            apiKey: apiKey,
            style: style
        )
        if provider == nil {
            error = "Couldn't save. Check the base URL and try a unique label."
            return
        }
        Task { await state.refreshModels() }
        dismiss()
    }
}

private struct CustomProviderRow: View {
    @EnvironmentObject var state: AppState
    let provider: CustomProvider
    @State private var showEdit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showEdit = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.label)
                            .foregroundStyle(Theme.textPrimary)
                        Text(provider.style.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Text(provider.baseURL)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(state.apiKey(for: provider.providerID).isEmpty ? "No key" : "••••••")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .sheet(isPresented: $showEdit) {
                EditCustomProviderView(provider: provider)
            }

            CustomProviderModelsSection(provider: provider)
        }
    }
}

/// Inline list of the models the app already discovered for this custom
/// provider, plus a Refresh button. Empty when the catalog hasn't run yet.
private struct CustomProviderModelsSection: View {
    @EnvironmentObject var state: AppState
    let provider: CustomProvider

    private var models: [AIModel] {
        state.providerResults
            .first(where: { $0.provider == provider.providerID })?
            .models ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Models")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    Task { await state.refreshModels() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if models.isEmpty {
                Text("No models loaded yet. Tap refresh.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(models) { model in
                    Text("• " + state.displayName(for: model))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.top, 8)
        .padding(.leading, 16)
        .padding(.bottom, 12)
    }
}

/// Edit base URL, endpoint type, and API key for an existing custom provider.
private struct EditCustomProviderView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let provider: CustomProvider

    @State private var label: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var style: CustomProviderStyle = .openAI

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    TextField("Label", text: $label)
                }
                Section {
                    Picker("Endpoint type", selection: $style) {
                        ForEach(CustomProviderStyle.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Endpoint")
                } footer: {
                    Text(style.detail)
                }
                Section("API key") {
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Edit provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        state.updateCustomProvider(
                            provider,
                            label: label,
                            baseURL: baseURL,
                            style: style,
                            apiKey: apiKey
                        )
                        Task { await state.refreshModels() }
                        dismiss()
                    }
                    .disabled(label.isEmpty || baseURL.isEmpty)
                }
            }
            .onAppear {
                label = provider.label
                baseURL = provider.baseURL
                style = provider.style
                apiKey = state.apiKey(for: provider.providerID)
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
                        Text("AnyProv Code")
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
                            Text("An open-source iOS client for any AI provider, paired with a desktop coding server.")
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
    }
}

#Preview {
    AppSettingsView()
        .environmentObject(AppState(secrets: KeychainSecretStore()))
}
