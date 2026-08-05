import Foundation

/// Factory + fan-out for listing models across every configured provider.
public struct ModelCatalog: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    /// Build the client for a provider.
    public func provider(_ id: ProviderID, customBaseURL: URL? = nil) -> ModelProvider {
        switch id {
        case .anthropic: return AnthropicProvider(http: http)
        case .google: return GoogleProvider(http: http)
        case .openai, .groq, .openrouter, .xai, .mistral:
            return OpenAICompatibleProvider(id: id, http: http)
        case .custom:
            // Custom providers are OpenAI-compatible at their own base URL.
            return OpenAICompatibleProvider(id: id, http: http, baseURLOverride: customBaseURL)
        }
    }

    /// Per-provider outcome of a catalog refresh.
    public struct ProviderResult: Sendable, Identifiable {
        public let provider: ProviderID
        public let models: [AIModel]
        public let error: String?
        public var id: String { provider.rawValue }

        public init(provider: ProviderID, models: [AIModel], error: String? = nil) {
            self.provider = provider
            self.models = models
            self.error = error
        }
    }

    /// Fetch models from all providers that have a non-empty key, concurrently.
    /// Never throws: failures are captured per-provider so one bad key doesn't
    /// hide the others.
    public func fetchAll(keys: [ProviderID: String]) async -> [ProviderResult] {
        let configured = keys.filter { !$0.value.isEmpty }
        return await withTaskGroup(of: ProviderResult.self) { group in
            for (id, key) in configured {
                group.addTask {
                    do {
                        let models = try await provider(id).listModels(apiKey: key)
                        return ProviderResult(provider: id, models: models, error: nil)
                    } catch {
                        let message = (error as? ProviderError)?.errorDescription
                            ?? error.localizedDescription
                        return ProviderResult(provider: id, models: [], error: message)
                    }
                }
            }
            var results: [ProviderResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.provider.rawValue < $1.provider.rawValue }
        }
    }
}
