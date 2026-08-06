import Foundation
import SwiftUI
import Combine
import MobileAICore

/// Root observable app state: secrets, model catalog, environments, GitHub
/// token, server pairing, and the current composer selections.
@MainActor
final class AppState: ObservableObject {
    // Secrets & clients
    let secrets: SecretStore
    let catalog: ModelCatalog
    let serverClient = ServerClient()
    let skillManager = SkillManager()
    let mcpManager = MCPManager()
    let artifactStore = ArtifactStore()
    let skillsMCPClient = SkillsMCPClient()
    let codeSessionStore = CodeSessionStore()
    let settingsSync = SettingsSync()

    /// Your GitHub OAuth app client id for Device Flow. Replace before shipping;
    /// can also be provided at runtime via Settings.
    @AppStorage("githubClientID") var githubClientID: String = ""

    // Composer selections (mirror the home screen controls)
    @Published var selectedRepo: GitHubRepo?
    @Published var selectedEnvironment: EnvironmentConfig?
    @Published var selectedModel: AIModel?
    @Published var effort: Effort = .high
    @Published var permissionMode: PermissionMode = .acceptEdits

    /// User-renamed models, keyed by `"provider:modelID"`. Empty entries are
    /// treated as "use the upstream name".
    @Published var modelAliases: [String: String] = [:]

    /// When true, every assistant message expands its Thinking section
    /// by default. When false, thinking collapses behind a one-line preview.
    @AppStorage("alwaysExpandThinking.v1") var alwaysExpandThinking: Bool = false

    /// When non-nil, the iOS app will push its settings to this GitHub
    /// repo on every change (and pull on launch when a token is linked).
    @AppStorage("settingsSyncRepoFullName.v1") var settingsSyncRepoFullName: String?

    // Catalog state
    @Published var providerResults: [ModelCatalog.ProviderResult] = []
    @Published var isLoadingModels = false

    // Custom (user-defined OpenAI-compatible) providers
    @Published var customProviders: [CustomProvider] = []

    // Environments (persisted)
    @Published var environments: [EnvironmentConfig] = []

    // Synced git repos for skills + MCP. Owned by the desktop server (it
    // has `git` in PATH); the iOS app asks the desktop to sync on connect
    // and applies the `skills_sync`/`mcp_sync` payloads to its local cache.
    @Published var skillsRepoURL: String = ""
    @Published var skillsRepoBranch: String = "main"
    @Published var mcpRepoURL: String = ""
    @Published var mcpRepoBranch: String = "main"

    // Server pairing
    @Published var serverEndpoint: ServerClient.Endpoint?
    @Published var serverToken: String?
    @Published var serverName: String?

    // Chat state (per-chat toggles live on `ChatViewModel`; nothing here yet.)

    private let environmentsKey = "environments.v1"
    private let skillsRepoKey = "skillsRepoURL.v1"
    private let skillsBranchKey = "skillsRepoBranch.v1"
    private let mcpRepoKey = "mcpRepoURL.v1"
    private let mcpBranchKey = "mcpRepoBranch.v1"
    private let customProvidersKey = "customProviders.v1"
    private let modelAliasesKey = "modelAliases.v1"

    init(secrets: SecretStore) {
        self.secrets = secrets
        self.catalog = ModelCatalog()
        loadEnvironments()
        loadSyncedRepos()
        loadCustomProviders()
        loadModelAliases()
        seedDefaultEnvironmentIfNeeded()
    }

    // MARK: - Custom providers

    func addCustomProvider(
        label: String,
        baseURL: String,
        apiKey: String,
        style: CustomProviderStyle = .openAI
    ) -> CustomProvider? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = Self.normalizeBaseURL(baseURL)
        guard !trimmedLabel.isEmpty, !normalizedURL.isEmpty else { return nil }
        guard URL(string: normalizedURL) != nil else { return nil }
        let slug = Self.slugify(trimmedLabel)
        guard !slug.isEmpty else { return nil }
        if customProviders.contains(where: { $0.id == slug }) { return nil }
        let provider = CustomProvider(
            id: slug,
            label: trimmedLabel,
            baseURL: normalizedURL,
            style: style
        )
        customProviders.append(provider)
        saveCustomProviders()
        if !apiKey.isEmpty {
            setAPIKey(apiKey, for: provider.providerID)
        }
        return provider
    }

    func updateCustomProvider(
        _ provider: CustomProvider,
        label: String,
        baseURL: String,
        style: CustomProviderStyle,
        apiKey: String?
    ) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = Self.normalizeBaseURL(baseURL)
        guard !trimmedLabel.isEmpty, !normalizedURL.isEmpty else { return }
        guard let idx = customProviders.firstIndex(where: { $0.id == provider.id }) else { return }
        customProviders[idx].label = trimmedLabel
        customProviders[idx].baseURL = normalizedURL
        customProviders[idx].style = style
        saveCustomProviders()
        if let apiKey {
            setAPIKey(apiKey, for: provider.providerID)
        }
    }

    func deleteCustomProvider(_ provider: CustomProvider) {
        customProviders.removeAll { $0.id == provider.id }
        setAPIKey("", for: provider.providerID)
        providerResults.removeAll { $0.provider == provider.providerID }
        if selectedModel?.provider == provider.providerID { selectedModel = nil }
        saveCustomProviders()
    }

    /// Resolve the base URL for a custom provider, if applicable.
    func baseURL(for provider: ProviderID) -> URL? {
        guard let custom = customProvider(for: provider),
              let url = URL(string: custom.baseURL) else {
            return nil
        }
        return url
    }

    /// Resolve API style for a custom provider (built-ins return nil).
    func apiStyle(for provider: ProviderID) -> CustomProviderStyle? {
        customProvider(for: provider)?.style
    }

    func customProvider(for provider: ProviderID) -> CustomProvider? {
        guard let slug = provider.customSlug else { return nil }
        return customProviders.first(where: { $0.id == slug })
    }

    /// Strip trailing slashes and accidental path suffixes users paste from docs.
    static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        let suffixes = ["/chat/completions", "/messages", "/models"]
        for suffix in suffixes where lower.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            while s.hasSuffix("/") { s.removeLast() }
        }
        return s
    }

    private func loadCustomProviders() {
        guard let data = UserDefaults.standard.data(forKey: customProvidersKey),
              let decoded = try? JSONDecoder().decode([CustomProvider].self, from: data)
        else { return }
        customProviders = decoded
    }

    private func saveCustomProviders() {
        if let data = try? JSONEncoder().encode(customProviders) {
            UserDefaults.standard.set(data, forKey: customProvidersKey)
        }
    }

    static func slugify(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed
    }

    // MARK: - Synced repos (URL hints shown in Settings; the desktop owns the real ones)

    func updateSkillsRepo(url: String, branch: String) {
        skillsRepoURL = url
        skillsRepoBranch = branch
        UserDefaults.standard.set(url, forKey: skillsRepoKey)
        UserDefaults.standard.set(branch, forKey: skillsBranchKey)
    }

    func updateMCPRepo(url: String, branch: String) {
        mcpRepoURL = url
        mcpRepoBranch = branch
        UserDefaults.standard.set(url, forKey: mcpRepoKey)
        UserDefaults.standard.set(branch, forKey: mcpBranchKey)
    }

    private func loadSyncedRepos() {
        skillsRepoURL = UserDefaults.standard.string(forKey: skillsRepoKey) ?? ""
        skillsRepoBranch = UserDefaults.standard.string(forKey: skillsBranchKey) ?? "main"
        mcpRepoURL = UserDefaults.standard.string(forKey: mcpRepoKey) ?? ""
        mcpRepoBranch = UserDefaults.standard.string(forKey: mcpBranchKey) ?? "main"
    }

    // MARK: Secrets convenience

    func apiKey(for provider: ProviderID) -> String {
        secrets.get(SecretKey.providerAPIKey(provider)) ?? ""
    }

    /// Key used for live API calls. Local OpenAI-compatible hosts (Ollama, etc.)
    /// often ignore auth — if the user left the key blank on a custom OpenAI-style
    /// provider, send a placeholder bearer token instead of falling back to OpenAI.
    func resolvedAPIKey(for provider: ProviderID) -> String {
        let stored = apiKey(for: provider)
        if !stored.isEmpty { return stored }
        if case .custom = provider, apiStyle(for: provider) == .openAI {
            return "local"
        }
        return ""
    }

    func setAPIKey(_ key: String, for provider: ProviderID) {
        secrets.set(key.isEmpty ? nil : key, for: SecretKey.providerAPIKey(provider))
    }

    var githubToken: String? {
        get { secrets.get(SecretKey.githubToken) }
        set { secrets.set(newValue, for: SecretKey.githubToken) }
    }

    var allModels: [AIModel] {
        providerResults.flatMap(\.models)
    }

    // MARK: Models

    func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        var keys: [ProviderID: String] = [:]
        var customBaseURLs: [ProviderID: URL] = [:]
        var styles: [ProviderID: CustomProviderStyle] = [:]
        for provider in ProviderID.allBuiltInCases {
            let key = apiKey(for: provider)
            if !key.isEmpty { keys[provider] = key }
        }
        for custom in customProviders {
            let pid = custom.providerID
            // Always try to list customs that have a base URL. resolvedAPIKey
            // supplies a local placeholder for keyless OpenAI-compatible hosts.
            let key = resolvedAPIKey(for: pid)
            if !key.isEmpty { keys[pid] = key }
            if let url = URL(string: custom.baseURL) { customBaseURLs[pid] = url }
            styles[pid] = custom.style
        }
        providerResults = await catalog.fetchAll(
            keys: keys,
            customBaseURLs: customBaseURLs,
            styles: styles
        )
        // Drop a selection that no longer has a key / vanished from catalog.
        if let selected = selectedModel {
            let stillListed = allModels.contains(where: { $0.id == selected.id })
            let canCall = !resolvedAPIKey(for: selected.provider).isEmpty
            if !stillListed || !canCall {
                selectedModel = allModels.first
            }
        } else {
            selectedModel = allModels.first
        }
    }

    // MARK: Environments

    func addOrUpdate(_ env: EnvironmentConfig) {
        if let idx = environments.firstIndex(where: { $0.name == env.name }) {
            environments[idx] = env
        } else {
            environments.append(env)
        }
        saveEnvironments()
    }

    func delete(_ env: EnvironmentConfig) {
        environments.removeAll { $0.name == env.name }
        saveEnvironments()
    }

    private func loadEnvironments() {
        guard let data = UserDefaults.standard.data(forKey: environmentsKey),
              let decoded = try? JSONDecoder().decode([EnvironmentConfig].self, from: data)
        else { return }
        environments = decoded
    }

    private func saveEnvironments() {
        if let data = try? JSONEncoder().encode(environments) {
            UserDefaults.standard.set(data, forKey: environmentsKey)
        }
    }

    private func seedDefaultEnvironmentIfNeeded() {
        if environments.isEmpty {
            let def = EnvironmentConfig(name: "Default", networkAccess: .trusted)
            environments = [def]
            selectedEnvironment = def
            saveEnvironments()
        } else if selectedEnvironment == nil {
            selectedEnvironment = environments.first
        }
    }

    // MARK: Model selection for a session

    /// Build the `ModelSelection` the server needs, pulling the key from Keychain.
    func modelSelectionForSession() -> ModelSelection? {
        guard let model = selectedModel else { return nil }
        let key = resolvedAPIKey(for: model.provider)
        guard !key.isEmpty else { return nil }
        let custom = customProvider(for: model.provider)
        return ModelSelection(
            provider: model.provider,
            model: model.modelID,
            effort: effort,
            apiKey: key,
            baseURL: custom?.baseURL,
            apiStyle: custom?.style
        )
    }

    var canStartSession: Bool {
        selectedRepo != nil && modelSelectionForSession() != nil && serverToken != nil
    }

    // MARK: - Model aliases

    /// Stable key for the alias table — survives custom provider slugs.
    static func aliasKey(provider: ProviderID, modelID: String) -> String {
        "\(provider.rawValue):\(modelID)"
    }

    func setAlias(_ alias: String?, for provider: ProviderID, modelID: String) {
        let key = Self.aliasKey(provider: provider, modelID: modelID)
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            modelAliases[key] = trimmed
        } else {
            modelAliases.removeValue(forKey: key)
        }
        saveModelAliases()
    }

    /// Display name shown in the UI: alias if present, otherwise the upstream name.
    func displayName(for model: AIModel) -> String {
        let key = Self.aliasKey(provider: model.provider, modelID: model.modelID)
        return modelAliases[key] ?? model.displayName
    }

    private func loadModelAliases() {
        guard let data = UserDefaults.standard.data(forKey: modelAliasesKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        modelAliases = decoded
    }

    private func saveModelAliases() {
        if let data = try? JSONEncoder().encode(modelAliases) {
            UserDefaults.standard.set(data, forKey: modelAliasesKey)
        }
    }

    // MARK: - Settings sync

    /// Build a JSON snapshot of the current settings. Used by SettingsSync.
    func snapshotForSync() -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            schemaVersion: AppSettingsSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            alwaysExpandThinking: alwaysExpandThinking,
            defaultPermissionMode: permissionMode,
            defaultEffort: effort,
            environments: environments,
            customProviders: customProviders,
            modelAliases: modelAliases,
            skillsRepoURL: skillsRepoURL,
            skillsRepoBranch: skillsRepoBranch,
            mcpRepoURL: mcpRepoURL,
            mcpRepoBranch: mcpRepoBranch
        )
    }

    /// Apply a snapshot to the live state. The user can review before
    /// accepting on the Settings screen.
    func applySnapshot(_ snapshot: AppSettingsSnapshot) {
        alwaysExpandThinking = snapshot.alwaysExpandThinking
        permissionMode = snapshot.defaultPermissionMode
        effort = snapshot.defaultEffort
        environments = snapshot.environments
        saveEnvironments()
        customProviders = snapshot.customProviders
        saveCustomProviders()
        modelAliases = snapshot.modelAliases
        saveModelAliases()
        skillsRepoURL = snapshot.skillsRepoURL
        skillsRepoBranch = snapshot.skillsRepoBranch
        UserDefaults.standard.set(skillsRepoURL, forKey: skillsRepoKey)
        UserDefaults.standard.set(skillsRepoBranch, forKey: skillsBranchKey)
        mcpRepoURL = snapshot.mcpRepoURL
        mcpRepoBranch = snapshot.mcpRepoBranch
        UserDefaults.standard.set(mcpRepoURL, forKey: mcpRepoKey)
        UserDefaults.standard.set(mcpRepoBranch, forKey: mcpBranchKey)
        if selectedEnvironment == nil { selectedEnvironment = environments.first }
    }
}
