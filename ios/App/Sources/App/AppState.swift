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

    // Environments (persisted)
    @Published var environments: [EnvironmentConfig] = []

    // Server pairing
    @Published var serverEndpoint: ServerClient.Endpoint?
    @Published var serverToken: String?
    @Published var serverName: String?

    // Chat state
    @Published var showChat = false
    @Published var chatConnectors: Set<String> = ["gmail", "google-calendar", "google-drive"]
    @Published var chatSkills: Set<String> = ["web-search"]
    @Published var chatWebSearchEnabled = true
    @Published var chatResearchEnabled = false
    @Published var chatHealthEnabled = false
    @Published var chatConnectorDiscoveryEnabled = true

    private let environmentsKey = "environments.v1"

    init(secrets: SecretStore) {
        self.secrets = secrets
        self.catalog = ModelCatalog()
        loadEnvironments()
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

    // MARK: Models

    func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        var keys: [ProviderID: String] = [:]
        for provider in ProviderID.allCases {
            let key = apiKey(for: provider)
            if !key.isEmpty { keys[provider] = key }
        }
        providerResults = await catalog.fetchAll(keys: keys)
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
