import Foundation

/// Factory + fan-out for listing models across every configured provider.
public struct ModelCatalog: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    /// Build the client for a provider.
    /// - Parameters:
    ///   - customBaseURL: Required for `.custom` providers; optional override for built-ins.
    ///   - style: API shape for custom (or overridden) endpoints. Defaults to OpenAI-compatible.
    public func provider(
        _ id: ProviderID,
        customBaseURL: URL? = nil,
        style: CustomProviderStyle? = nil
    ) -> ModelProvider {
        switch id {
        case .anthropic:
            return AnthropicProvider(id: id, http: http, baseURL: customBaseURL)
        case .google:
            return GoogleProvider(http: http, baseURL: customBaseURL)
        case .openai, .groq, .openrouter, .xai, .mistral, .minimax:
            return OpenAICompatibleProvider(id: id, http: http, baseURL: customBaseURL)
        case .localMetal:
            return LocalMetalProvider()
        case .appleFoundation:
            return AppleFoundationProvider()
        case .custom:
            let resolvedStyle = style ?? .openAI
            switch resolvedStyle {
            case .anthropic:
                return AnthropicProvider(id: id, http: http, baseURL: customBaseURL)
            case .openAI:
                return OpenAICompatibleProvider(id: id, http: http, baseURL: customBaseURL)
            }
        }
    }

    /// Per-provider outcome of a catalog refresh.
    public struct ProviderResult: Sendable, Identifiable {
        public let provider: ProviderID
        public let models: [AIModel]
        public let error: String?
        public var id: String { provider.rawValue }

        public init(provider: ProviderID, models: [AIModel], error: String?) {
            self.provider = provider
            self.models = models
            self.error = error
        }
    }

    /// Fetch models from all providers that have a non-empty key, concurrently.
    public func fetchAll(keys: [ProviderID: String]) async -> [ProviderResult] {
        await fetchAll(keys: keys, customBaseURLs: [:], styles: [:])
    }

    /// Fetch models with optional per-provider base URLs and API styles.
    public func fetchAll(
        keys: [ProviderID: String],
        customBaseURLs: [ProviderID: URL],
        styles: [ProviderID: CustomProviderStyle] = [:]
    ) async -> [ProviderResult] {
        var configured = keys.filter { !$0.value.isEmpty }
        // Always list on-device chat providers (no API key).
        if configured[.localMetal] == nil {
            configured[.localMetal] = "local"
        }
        if configured[.appleFoundation] == nil {
            configured[.appleFoundation] = "local"
        }
        return await withTaskGroup(of: ProviderResult.self) { group in
            for (id, key) in configured {
                let baseURL = customBaseURLs[id]
                let style = styles[id]
                group.addTask {
                    do {
                        // Custom providers without a base URL cannot list models.
                        if case .custom = id, baseURL == nil {
                            throw ProviderError.transport(
                                "Custom provider is missing a base URL. Edit it in Settings."
                            )
                        }
                        let models = try await self.provider(
                            id,
                            customBaseURL: baseURL,
                            style: style
                        ).listModels(apiKey: key)
                        return ModelCatalog.ProviderResult(provider: id, models: models, error: nil)
                    } catch {
                        let message = (error as? ProviderError)?.errorDescription
                            ?? error.localizedDescription
                        return ModelCatalog.ProviderResult(provider: id, models: [], error: message)
                    }
                }
            }
            var results: [ProviderResult] = []
            for await r in group { results.append(r) }
            return results.sorted { $0.provider.rawValue < $1.provider.rawValue }
        }
    }
}
