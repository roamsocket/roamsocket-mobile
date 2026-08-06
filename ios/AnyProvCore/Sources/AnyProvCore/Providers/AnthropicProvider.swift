import Foundation

/// Anthropic Messages provider: `GET {base}/models`, `POST {base}/messages`.
/// Also used for user-defined Anthropic-compatible endpoints.
public struct AnthropicProvider: ModelProvider {
    public let id: ProviderID
    private let http: HTTPClient
    private let baseURL: URL

    public init(
        id: ProviderID = .anthropic,
        http: HTTPClient = URLSessionHTTPClient(),
        baseURL: URL? = nil
    ) {
        self.id = id
        self.http = http
        if let baseURL {
            var s = baseURL.absoluteString
            while s.hasSuffix("/") { s.removeLast() }
            self.baseURL = URL(string: s) ?? baseURL
        } else {
            self.baseURL = URL(string: "https://api.anthropic.com/v1")!
        }
    }

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
                    provider: id,
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
    }

    /// Anthropic message: `content` is either a plain string or multimodal blocks.
    private struct Message: Encodable {
        let role: String
        let content: Content

        enum Content: Encodable {
            case text(String)
            case blocks([Block])

            func encode(to encoder: Encoder) throws {
                switch self {
                case .text(let value):
                    var container = encoder.singleValueContainer()
                    try container.encode(value)
                case .blocks(let blocks):
                    var container = encoder.unkeyedContainer()
                    for block in blocks {
                        try container.encode(block)
                    }
                }
            }
        }

        enum Block: Encodable {
            case text(String)
            case image(mimeType: String, base64: String)

            private enum CodingKeys: String, CodingKey {
                case type, text, source
            }

            private enum SourceKeys: String, CodingKey {
                case type, media_type, data
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let value):
                    try container.encode("text", forKey: .type)
                    try container.encode(value, forKey: .text)
                case .image(let mimeType, let base64):
                    try container.encode("image", forKey: .type)
                    var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                    try source.encode("base64", forKey: .type)
                    try source.encode(mimeType, forKey: .media_type)
                    try source.encode(base64, forKey: .data)
                }
            }
        }

        init(from message: ProviderChatMessage) {
            role = message.role.rawValue
            if message.images.isEmpty {
                content = .text(message.content)
            } else {
                var blocks: [Block] = []
                for image in message.images {
                    blocks.append(.image(mimeType: image.mimeType, base64: image.base64Data))
                }
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                blocks.append(.text(text.isEmpty ? "Analyze this image." : text))
                content = .blocks(blocks)
            }
        }
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
        // Merge all system turns (e.g. Health snapshot + future skills).
        let systemParts = messages.filter { $0.role == .system }.map(\.content)
        let system = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }.map { Message(from: $0) }
        let hasImages = messages.contains(where: \.hasImages)
        let body = MessagesRequest(
            model: model,
            max_tokens: hasImages ? 2048 : 1024,
            messages: turns,
            system: system
        )
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
}
