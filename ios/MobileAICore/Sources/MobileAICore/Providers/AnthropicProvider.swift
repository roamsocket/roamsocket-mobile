import Foundation

/// Anthropic provider: `GET https://api.anthropic.com/v1/models`.
public struct AnthropicProvider: ModelProvider {
    public let id: ProviderID = .anthropic
    private let http: HTTPClient
    private let baseURL = URL(string: "https://api.anthropic.com/v1")!

    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let id: String
            let display_name: String?
        }
        let data: [Model]
    }

    public func listModels(apiKey: String) async throws -> [AIModel] {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        let request = ProviderHTTP.get(
            baseURL.appendingPathComponent("models"),
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ]
        )
        let (data, response) = try await http.data(for: request)
        try ProviderHTTP.validate(data, response)
        do {
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            return list.data.map {
                AIModel(
                    provider: .anthropic,
                    modelID: $0.id,
                    displayName: $0.display_name ?? $0.id
                )
            }
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }
}
