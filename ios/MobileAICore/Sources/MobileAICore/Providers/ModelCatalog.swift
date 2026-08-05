import Foundation

/// Factory + fan-out for listing models across every configured provider.
public struct ModelCatalog: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    /// Build the client for a provider. For custom providers, pass
    /// `customBaseURL` so the provider knows where to send requests.
    public func provider(_ id: ProviderID, customBaseURL: URL? = nil) -> ModelProvider {
        switch id {
        case .anthropic:
            return AnthropicProvider(http: http, baseURL: customBaseURL)
        case .google:
            return GoogleProvider(http: http, baseURL: customBaseURL)
        case .openai, .groq, .openrouter, .xai, .mistral:
            return OpenAICompatibleProvider(id: id, http: http, baseURL: customBaseURL)
        default:
            // Custom providers (rawValue starts with "custom:") use the
            // OpenAI-compatible wire by default. Anthropic-style custom
            // providers (detected via /v1/messages path) go through
            // AnthropicProvider.
            if let url = customBaseURL,
               let style = detectStyle(url: url) {
                switch style {
                case .anthropic:
                    return AnthropicProvider(http: http, baseURL: url)
                case .openAI:
                    return OpenAICompatibleProvider(id: id, http: http, baseURL: url)
                }
            }
            return OpenAICompatibleProvider(id: id, http: http, baseURL: customBaseURL)
        }
    }

    /// Per-provider outcome of a catalog refresh.
    public struct ProviderResult: Sendable, Identifiable {
        public let provider: ProviderID
        public let models: [AIModel]
        public let error: String?
        public var id: String { provider.rawValue }
    }

    /// Fetch models from all providers that have a non-empty key, concurrently.
    /// Never throws: failures are captured per-provider so one bad key doesn't
    /// hide the others.
    public func fetchAll(keys: [ProviderID: String]) async -> [ProviderResult] {
        return await fetchAll(keys: keys, customBaseURLs: [:])
    }

    /// Fetch models, threading through a per-provider custom base URL (used
    /// for user-defined OpenAI-compatible and Anthropic-style endpoints).
    public func fetchAll(
        keys: [ProviderID: String],
        customBaseURLs: [ProviderID: URL]
    ) async -> [ProviderResult] {
        let configured = keys.filter { !$0.value.isEmpty }
        return await withTaskGroup(of: ProviderResult.self) { group in
            for (id, key) in configured {
                let baseURL = customBaseURLs[id]
                group.addTask {
                    do {
                        let models = try await self.provider(id, customBaseURL: baseURL).listModels(apiKey: key)
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

    private enum Style { case openAI, anthropic }
    private func detectStyle(url: URL) -> Style? {
        if url.path.contains("/v1/messages") { return .anthropic }
        if url.path.contains("/v1/chat/completions") { return .openAI }
        return nil
    }
}
