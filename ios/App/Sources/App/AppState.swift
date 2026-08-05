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

    // Server pairing
    @Published var serverEndpoint: ServerClient.Endpoint?
    @Published var serverToken: String?
    @Published var serverName: String?

    // Chat state (per-chat toggles live on `ChatViewModel`; nothing here yet.)

    private let environmentsKey = "environments.v1"
    private let customProvidersKey = "customProviders.v1"

    init(secrets: SecretStore) {
        self.secrets = secrets
        self.catalog = ModelCatalog()
        loadEnvironments()
        loadCustomProviders()
        seedDefaultEnvironmentIfNeeded()
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

    /// Display name for a provider — looks up the custom label if the id is a
    /// `.custom(slug)` and the slug is in `customProviders`.
    func displayName(for provider: ProviderID) -> String {
        if let slug = provider.customSlug, let custom = customProviders.first(where: { $0.id == slug }) {
            return custom.label
        }
        return provider.displayName
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

    // MARK: Custom providers

    func addCustomProvider(label: String, baseURL: String, apiKey: String) -> CustomProvider? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedURL.isEmpty else { return nil }
        guard URL(string: trimmedURL) != nil else { return nil }
        // Slug must be unique; reuse the existing one if the label resolves to it.
        let slug = Self.slugify(trimmedLabel)
        guard !slug.isEmpty else { return nil }
        if customProviders.contains(where: { $0.id == slug }) {
            return nil // duplicate
        }
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
        setAPIKey("", for: provider.providerID) // wipe the key
        providerResults.removeAll { $0.provider == provider.providerID }
        if selectedModel?.provider == provider.providerID { selectedModel = nil }
        saveCustomProviders()
    }

    /// Validate a candidate slug; returns nil if it's acceptable, or a reason.
    func customProviderConflict(slug: String) -> String? {
        if slug.isEmpty { return "Slug is empty." }
        if customProviders.contains(where: { $0.id == slug }) { return "A provider with this id already exists." }
        return nil
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

    // MARK: Models

    func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        var keys: [ProviderID: String] = [:]
        for provider in ProviderID.allBuiltInCases {
            let key = apiKey(for: provider)
            if !key.isEmpty { keys[provider] = key }
        }
        for custom in customProviders {
            let pid = custom.providerID
            let key = apiKey(for: pid)
            if !key.isEmpty { keys[pid] = key }
        }

        // Use a custom provider factory that knows each custom base URL.
        providerResults = await fetchAllWithCustom(keys: keys)
        if selectedModel == nil { selectedModel = allModels.first }
    }

    private func fetchAllWithCustom(keys: [ProviderID: String]) async -> [ModelCatalog.ProviderResult] {
        let configured = keys.filter { !$0.value.isEmpty }
        return await withTaskGroup(of: ModelCatalog.ProviderResult.self) { group in
            for (id, key) in configured {
                let baseURL = self.baseURL(for: id)
                group.addTask {
                    do {
                        let client = self.catalog.provider(id, customBaseURL: baseURL)
                        let models = try await client.listModels(apiKey: key)
                        return ModelCatalog.ProviderResult(provider: id, models: models, error: nil)
                    } catch {
                        let message = (error as? ProviderError)?.errorDescription
                            ?? error.localizedDescription
                        return ModelCatalog.ProviderResult(provider: id, models: [], error: message)
                    }
                }
            }
            var results: [ModelCatalog.ProviderResult] = []
            for await r in group { results.append(r) }
            return results.sorted { $0.provider.rawValue < $1.provider.rawValue }
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
        let key = apiKey(for: model.provider)
        guard !key.isEmpty else { return nil }
        let customBase = model.provider.customSlug.flatMap { slug -> String? in
            guard let custom = customProviders.first(where: { $0.id == slug }) else { return nil }
            return custom.baseURL
        }
        return ModelSelection(
            provider: model.provider,
            model: model.modelID,
            effort: effort,
            apiKey: key,
            customBaseUrl: customBase
        )
    }

    var canStartSession: Bool {
        selectedRepo != nil && modelSelectionForSession() != nil && serverToken != nil
    }
}
