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

    /// Your GitHub OAuth app client id for Device Flow. Replace before shipping;
    /// can also be provided at runtime via Settings.
    @AppStorage("githubClientID") var githubClientID: String = ""

    // Composer selections (mirror the home screen controls)
    @Published var selectedRepo: GitHubRepo?
    @Published var selectedEnvironment: EnvironmentConfig?
    @Published var selectedModel: AIModel?
    @Published var effort: Effort = .high
    @Published var permissionMode: PermissionMode = .acceptEdits

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

    init(secrets: SecretStore) {
        self.secrets = secrets
        self.catalog = ModelCatalog()
        loadEnvironments()
        loadSyncedRepos()
        loadCustomProviders()
        seedDefaultEnvironmentIfNeeded()
    }

    // MARK: - Custom providers

    func addCustomProvider(label: String, baseURL: String, apiKey: String) -> CustomProvider? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedURL.isEmpty else { return nil }
        guard URL(string: trimmedURL) != nil else { return nil }
        let slug = Self.slugify(trimmedLabel)
        guard !slug.isEmpty else { return nil }
        if customProviders.contains(where: { $0.id == slug }) { return nil }
        let provider = CustomProvider(id: slug, label: trimmedLabel, baseURL: trimmedURL)
        customProviders.append(provider)
        saveCustomProviders()
        if !apiKey.isEmpty {
            setAPIKey(apiKey, for: provider.providerID)
        }
        return provider
    }

    func updateCustomProvider(_ provider: CustomProvider, label: String, baseURL: String, apiKey: String?) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedURL.isEmpty else { return }
        guard let idx = customProviders.firstIndex(where: { $0.id == provider.id }) else { return }
        customProviders[idx].label = trimmedLabel
        customProviders[idx].baseURL = trimmedURL
        saveCustomProviders()
        if let apiKey, !apiKey.isEmpty {
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
        guard let slug = provider.customSlug,
              let custom = customProviders.first(where: { $0.id == slug }),
              let url = URL(string: custom.baseURL) else {
            return nil
        }
        return url
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
        for provider in ProviderID.allBuiltInCases {
            let key = apiKey(for: provider)
            if !key.isEmpty { keys[provider] = key }
        }
        for custom in customProviders {
            let pid = custom.providerID
            let key = apiKey(for: pid)
            if !key.isEmpty { keys[pid] = key }
            if let url = URL(string: custom.baseURL) { customBaseURLs[pid] = url }
        }
        providerResults = await catalog.fetchAll(keys: keys, customBaseURLs: customBaseURLs)
        if selectedModel == nil { selectedModel = allModels.first }
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
        let key = apiKey(for: model.provider)
        guard !key.isEmpty else { return nil }
        return ModelSelection(provider: model.provider, model: model.modelID, effort: effort, apiKey: key)
    }

    var canStartSession: Bool {
        selectedRepo != nil && modelSelectionForSession() != nil && serverToken != nil
    }
}
