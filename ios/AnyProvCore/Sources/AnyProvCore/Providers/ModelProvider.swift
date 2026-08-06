import Foundation

/// Errors surfaced by provider clients.
public enum ProviderError: Error, LocalizedError, Equatable {
    case missingKey
    case http(status: Int, body: String)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "No API key configured for this provider."
        case let .http(status, body): return "HTTP \(status): \(body)"
        case let .decoding(msg): return "Failed to decode response: \(msg)"
        case let .transport(msg): return "Network error: \(msg)"
        }
    }
}

/// Minimal HTTP surface a provider needs, injectable for testing.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default `HTTPClient` backed by `URLSession`.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.transport("Non-HTTP response")
            }
            return (data, http)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }
}

/// A provider client that can list the models available for a given API key.
public protocol ModelProvider: Sendable {
    var id: ProviderID { get }
    /// Fetch the models this key can access. Throws `ProviderError`.
    func listModels(apiKey: String) async throws -> [AIModel]
    /// Send a single-turn chat completion. Returns the assistant's reply text.
    /// Throws `ProviderError`.
    func chat(model: String, apiKey: String, messages: [ProviderChatMessage], effort: Effort?) async throws -> String
}

/// A single message in a chat turn, scoped to provider APIs.
///
/// Text-only turns use `content` with an empty `images` array (the common path).
/// Vision / multimodal turns attach JPEG/PNG payloads in `images`; providers that
/// support vision encode them as base64 data URLs (OpenAI-compatible) or
/// Anthropic image blocks. Local Metal and other text-only engines ignore
/// images or reject them.
public struct ProviderChatMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    /// Inline image for multimodal chat (JPEG or PNG preferred).
    public struct ImageAttachment: Codable, Sendable, Hashable {
        /// MIME type, e.g. `image/jpeg` or `image/png`.
        public let mimeType: String
        /// Raw base64 (no data-URL prefix).
        public let base64Data: String

        public init(mimeType: String, base64Data: String) {
            self.mimeType = mimeType
            self.base64Data = base64Data
        }

        /// `data:{mime};base64,{data}` for OpenAI-compatible `image_url` payloads.
        public var dataURL: String {
            "data:\(mimeType);base64,\(base64Data)"
        }
    }

    public let role: Role
    public let content: String
    /// Optional images for vision models. Empty for text-only turns.
    public let images: [ImageAttachment]

    public init(role: Role, content: String, images: [ImageAttachment] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    public var hasImages: Bool { !images.isEmpty }

    enum CodingKeys: String, CodingKey {
        case role, content, images
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        images = try c.decodeIfPresent([ImageAttachment].self, forKey: .images) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        if !images.isEmpty {
            try c.encode(images, forKey: .images)
        }
    }
}

/// Shared helpers for building requests and validating responses.
enum ProviderHTTP {
    static func get(_ url: URL, headers: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    static func post(_ url: URL, headers: [String: String], body: Data) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }

    static func validate(_ data: Data, _ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.http(status: response.statusCode, body: body)
        }
    }
}
