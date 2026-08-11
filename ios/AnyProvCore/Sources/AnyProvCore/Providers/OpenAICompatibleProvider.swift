import Foundation

/// OpenAI-compatible provider used by OpenAI, Groq, OpenRouter, xAI, Mistral,
/// MiniMax, and user-defined custom endpoints. All expose `GET {base}/models`
/// with `Authorization: Bearer` and `POST {base}/chat/completions`.
public struct OpenAICompatibleProvider: ModelProvider {
    public let id: ProviderID
    private let http: HTTPClient
    private let baseURL: URL

    public init(id: ProviderID, http: HTTPClient = URLSessionHTTPClient(), baseURL: URL? = nil) {
        self.id = id
        self.http = http
        if let baseURL {
            self.baseURL = Self.normalized(baseURL)
        } else if let builtIn = Self.defaultBaseURL(for: id) {
            self.baseURL = builtIn
        } else {
            // Custom providers must pass baseURL; this is a last-resort guard.
            self.baseURL = URL(string: "http://invalid.invalid")!
        }
    }

    static func defaultBaseURL(for id: ProviderID) -> URL? {
        switch id {
        case .openai: return URL(string: "https://api.openai.com/v1")
        case .groq: return URL(string: "https://api.groq.com/openai/v1")
        case .openrouter: return URL(string: "https://openrouter.ai/api/v1")
        case .xai: return URL(string: "https://api.x.ai/v1")
        case .mistral: return URL(string: "https://api.mistral.ai/v1")
        case .minimax: return URL(string: "https://api.minimax.io/v1")
        case .anthropic, .google, .localMetal, .appleFoundation, .custom:
            return nil
        }
    }

    static func normalized(_ url: URL) -> URL {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) ?? url
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let id: String
            let context_length: Int?      // OpenRouter
            let context_window: Int?      // some providers
            let organization: String?     // OpenRouter vendor, e.g. "OpenAI"
            let is_free: Bool?            // OpenRouter free flag
            let pricing: Pricing?         // OpenRouter pricing
            struct Pricing: Decodable {
                let prompt: String?
                let completion: String?
            }
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
                    displayName: AIModel.prettifiedDisplayName(for: $0.id, provider: id),
                    contextWindow: $0.context_length ?? $0.context_window,
                    organization: $0.organization,
                    isFree: Self.freeFlag(for: $0)
                )
            }
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }

    /// OpenRouter free tier: `is_free` when present, else zero prompt + completion pricing.
    private static func freeFlag(for model: ModelList.Model) -> Bool? {
        if let flag = model.is_free { return flag }
        guard let pricing = model.pricing,
              let prompt = pricing.prompt,
              let completion = pricing.completion,
              Self.isZeroPrice(prompt),
              Self.isZeroPrice(completion)
        else { return nil }
        return true
    }

    private static func isZeroPrice(_ value: String) -> Bool {
        ["0", "0.0", "0.00", "0.000"].contains(value)
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Msg]
        let plugins: [Plugin]?

        /// OpenRouter plugin shape (e.g. the `web` search plugin).
        struct Plugin: Encodable {
            let id: String
            let max_results: Int?
            let search_prompt: String?
        }
    }

    /// OpenAI chat message: `content` is either a plain string or a multimodal
    /// array of text / image_url parts.
    private struct Msg: Encodable {
        let role: String
        let content: Content

        enum Content: Encodable {
            case text(String)
            case parts([Part])

            func encode(to encoder: Encoder) throws {
                switch self {
                case .text(let value):
                    var container = encoder.singleValueContainer()
                    try container.encode(value)
                case .parts(let parts):
                    var container = encoder.unkeyedContainer()
                    for part in parts {
                        try container.encode(part)
                    }
                }
            }
        }

        enum Part: Encodable {
            case text(String)
            case imageURL(String)

            private enum CodingKeys: String, CodingKey {
                case type, text, image_url
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let value):
                    try container.encode("text", forKey: .type)
                    try container.encode(value, forKey: .text)
                case .imageURL(let url):
                    try container.encode("image_url", forKey: .type)
                    try container.encode(["url": url], forKey: .image_url)
                }
            }
        }

        init(from message: ProviderChatMessage) {
            role = message.role.rawValue
            if message.images.isEmpty {
                content = .text(message.content)
            } else {
                var parts: [Part] = []
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parts.append(.text(text))
                }
                for image in message.images {
                    parts.append(.imageURL(image.dataURL))
                }
                // Some hosts require at least one text part when images are present.
                if parts.allSatisfy({
                    if case .imageURL = $0 { return true }
                    return false
                }) {
                    parts.insert(.text("Analyze this image."), at: 0)
                }
                content = .parts(parts)
            }
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let role: String; let content: String? }
            let message: Msg
        }
        let choices: [Choice]
    }

    public func chat(model: String, apiKey: String, messages: [ProviderChatMessage], effort: Effort?) async throws -> String {
        try await chat(
            model: model,
            apiKey: apiKey,
            messages: messages,
            effort: effort,
            webSearchQuery: nil
        )
    }

    public func chat(
        model: String,
        apiKey: String,
        messages: [ProviderChatMessage],
        effort: Effort?,
        webSearchQuery: String?
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        let turns = messages.map { Msg(from: $0) }
        // OpenRouter supports native web search via the `web` plugin. The model
        // host runs the search server-side and injects fresh results into the
        // request context — no client-side SERP scraping needed.
        let plugins: [ChatRequest.Plugin]?
        if id == .openrouter, let webSearchQuery, !webSearchQuery.isEmpty {
            plugins = [
                ChatRequest.Plugin(
                    id: "web",
                    max_results: 5,
                    search_prompt: webSearchQuery
                )
            ]
        } else {
            plugins = nil
        }
        let body = ChatRequest(model: model, messages: turns, plugins: plugins)
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
}
