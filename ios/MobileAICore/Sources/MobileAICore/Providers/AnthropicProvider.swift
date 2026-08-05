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

    private struct MessagesRequest: Encodable {
        let model: String
        let max_tokens: Int
        let messages: [Message]
        let system: String?
        struct Message: Encodable { let role: String; let content: String }
    }

    private struct MessagesResponse: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }
        let content: [Content]
    }

    public func chat(model: String, apiKey: String, messages: [ProviderChatMessage], effort: Effort?) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        let system = messages.first(where: { $0.role == .system })?.content
        let turns = messages.filter { $0.role != .system }.map { Msg(role: $0.role.rawValue, content: $0.content) }
        let body = MessagesRequest(model: model, max_tokens: 1024, messages: turns, system: system)
        let req = ProviderHTTP.post(
            baseURL.appendingPathComponent("messages"),
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            ],
            body: try JSONEncoder().encode(body)
        )
        let (data, response) = try await http.data(for: req)
        try ProviderHTTP.validate(data, response)
        do {
            let parsed = try JSONDecoder().decode(MessagesResponse.self, from: data)
            return parsed.content.compactMap { $0.text }.joined(separator: "\n")
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }

    private typealias Msg = MessagesRequest.Message
}
