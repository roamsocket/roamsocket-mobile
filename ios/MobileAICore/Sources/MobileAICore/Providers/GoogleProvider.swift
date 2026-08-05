import Foundation

/// Google Gemini provider: `GET https://generativelanguage.googleapis.com/v1beta/models?key=...`.
public struct GoogleProvider: ModelProvider {
    public let id: ProviderID = .google
    private let http: HTTPClient
    private let baseURL: URL

    public init(http: HTTPClient = URLSessionHTTPClient(), baseURL: URL? = nil) {
        self.http = http
        self.baseURL = baseURL ?? URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let name: String                 // "models/gemini-1.5-pro"
            let displayName: String?
            let inputTokenLimit: Int?
            let supportedGenerationMethods: [String]?
        }
        let models: [Model]
    }

    public func listModels(apiKey: String) async throws -> [AIModel] {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("models"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        let request = ProviderHTTP.get(components.url!, headers: [:])
        let (data, response) = try await http.data(for: request)
        try ProviderHTTP.validate(data, response)
        do {
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            return list.models
                // Only models that can generate content are usable for chat.
                .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
                .map {
                    let shortID = $0.name.replacingOccurrences(of: "models/", with: "")
                    return AIModel(
                        provider: .google,
                        modelID: shortID,
                        displayName: $0.displayName ?? shortID,
                        contextWindow: $0.inputTokenLimit
                    )
                }
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }

    public func chat(model: String, apiKey: String, messages: [ProviderChatMessage], effort: Effort?) async throws -> String {
        throw ProviderError.transport("Google chat is not yet wired. Use the desktop server for coding.")
    }
}
