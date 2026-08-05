import Foundation

/// OpenAI-compatible provider used by OpenAI, Groq, OpenRouter, xAI, Mistral,
/// and any user-defined custom endpoint. All expose `GET {base}/models` with
/// `Authorization: Bearer`.
public struct OpenAICompatibleProvider: ModelProvider {
    public let id: ProviderID
    private let http: HTTPClient
    private let baseURL: URL

    public init(id: ProviderID, http: HTTPClient = URLSessionHTTPClient(), baseURLOverride: URL? = nil) {
        self.id = id
        self.http = http
        self.baseURL = baseURLOverride ?? Self.baseURL(for: id)
    }

    static func baseURL(for id: ProviderID) -> URL {
        switch id {
        case .openai: return URL(string: "https://api.openai.com/v1")!
        case .groq: return URL(string: "https://api.groq.com/openai/v1")!
        case .openrouter: return URL(string: "https://openrouter.ai/api/v1")!
        case .xai: return URL(string: "https://api.x.ai/v1")!
        case .mistral: return URL(string: "https://api.mistral.ai/v1")!
        case .custom: return URL(string: "https://api.openai.com/v1")! // overridden at init
        case .anthropic, .google: return URL(string: "https://api.openai.com/v1")!
        }
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let id: String
            let context_length: Int?      // OpenRouter
            let context_window: Int?      // some providers
        }
        let data: [Model]
    }

    public func listModels(apiKey: String) async throws -> [AIModel] {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        let request = ProviderHTTP.get(
            baseURL.appendingPathComponent("models"),
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
        let (data, response) = try await http.data(for: request)
        try ProviderHTTP.validate(data, response)
        do {
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            return list.data.map {
                AIModel(
                    provider: id,
                    modelID: $0.id,
                    displayName: $0.id,
                    contextWindow: $0.context_length ?? $0.context_window
                )
            }
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Msg]
        struct Msg: Encodable { let role: String; let content: String }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let role: String; let content: String }
            let message: Msg
        }
        let choices: [Choice]
    }

    public func chat(model: String, apiKey: String, messages: [ProviderChatMessage], effort: Effort?) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        let turns = messages.map { Msg(role: $0.role.rawValue, content: $0.content) }
        let body = ChatRequest(model: model, messages: turns)
        let req = ProviderHTTP.post(
            baseURL.appendingPathComponent("chat/completions"),
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "content-type": "application/json",
            ],
            body: try JSONEncoder().encode(body)
        )
        let (data, response) = try await http.data(for: req)
        try ProviderHTTP.validate(data, response)
        do {
            let parsed = try JSONDecoder().decode(ChatResponse.self, from: data)
            return parsed.choices.first?.message.content ?? ""
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }

    private typealias Msg = ChatRequest.Msg
}
