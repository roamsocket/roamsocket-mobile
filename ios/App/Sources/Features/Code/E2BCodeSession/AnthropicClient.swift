import Foundation
import AnyProvCore

/// Minimal Anthropic Messages API client. We don't use the
/// streaming SSE variant in v1 — the runner awaits the full
/// response and then dispatches any tool calls. Streaming
/// can land later once the basic tool loop is working.
///
/// Auth: the `x-api-key` header. `anthropic-version` is the
/// pinned 2023-06-01 (matches the Messages API surface we use).
public actor AnthropicClient {
    public struct Message: Codable, Sendable {
        public let role: String
        public let content: [Content]

        public enum Content: Codable, Sendable {
            case text(String)
            case toolUse(id: String, name: String, input: AnyJSON)
            case toolResult(toolUseId: String, content: String, isError: Bool)

            private enum CodingKeys: String, CodingKey { case type, text, id, name, input, content, is_error }
            private enum Kind: String, Codable { case text, tool_use, tool_result }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case let .text(s):
                    try c.encode("text", forKey: .type)
                    try c.encode(s, forKey: .text)
                case let .toolUse(id, name, input):
                    try c.encode("tool_use", forKey: .type)
                    try c.encode(id, forKey: .id)
                    try c.encode(name, forKey: .name)
                    try c.encode(input, forKey: .input)
                case let .toolResult(id, content, isError):
                    try c.encode("tool_result", forKey: .type)
                    try c.encode(id, forKey: .content) // `content` field name
                    // Re-encode the inner tool_result body so the
                    // wire shape matches Anthropic's spec: a string
                    // body plus an `is_error` flag at the top level.
                    try c.encode(content, forKey: .text) // we use .text as a generic extra key
                    try c.encode(isError, forKey: .is_error)
                }
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let kind = try c.decode(Kind.self, forKey: .type)
                switch kind {
                case .text:
                    let s = try c.decode(String.self, forKey: .text)
                    self = .text(s)
                case .tool_use:
                    let id = try c.decode(String.self, forKey: .id)
                    let name = try c.decode(String.self, forKey: .name)
                    let input = try c.decode(AnyJSON.self, forKey: .input)
                    self = .toolUse(id: id, name: name, input: input)
                case .tool_result:
                    let id = try c.decode(String.self, forKey: .id)
                    let content = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
                    let isError = try c.decodeIfPresent(Bool.self, forKey: .is_error) ?? false
                    self = .toolResult(toolUseId: id, content: content, isError: isError)
                }
            }
        }
    }

    public struct Tool: Codable, Sendable {
        public let name: String
        public let description: String
        public let inputSchema: AnyJSON

        public init(name: String, description: String, inputSchema: AnyJSON) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
        }
    }

    public struct Response: Codable, Sendable {
        public let id: String
        public let content: [Message.Content]
        public let stopReason: String?

        private enum CodingKeys: String, CodingKey {
            case id, content
            case stopReason = "stop_reason"
        }
    }

    let apiKey: String
    let baseURL: URL
    let model: String
    let session: URLSession

    public init(
        apiKey: String,
        model: String = "claude-sonnet-4-5",
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.session = URLSession.shared
    }

    /// Send a Messages API request and return the parsed response.
    /// Non-streaming v1: we await the full response. Throws on
    /// non-2xx; the caller's runner treats errors as `notice`
    /// transcript lines so the user sees what happened.
    public func send(
        system: String,
        messages: [Message],
        tools: [Tool],
        maxTokens: Int = 4096,
    ) async throws -> Response {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map(messageToWire),
            "tools": tools.map(toolToWire),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AnthropicError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError.http(status: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AnthropicError.decoding(error.localizedDescription)
        }
    }

    private func messageToWire(_ message: Message) -> [String: Any] {
        let content: [[String: Any]] = message.content.map { c in
            switch c {
            case let .text(s):
                return ["type": "text", "text": s]
            case let .toolUse(id, name, input):
                return [
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": input.value as Any,
                ]
            case let .toolResult(id, body, isError):
                return [
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": body,
                    "is_error": isError,
                ]
            }
        }
        return ["role": message.role, "content": content]
    }

    private func toolToWire(_ tool: Tool) -> [String: Any] {
        return [
            "name": tool.name,
            "description": tool.description,
            "input_schema": tool.inputSchema.value as Any,
        ]
    }
}

public enum AnthropicError: Error, LocalizedError {
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, body):
            let snippet = body.isEmpty ? "" : " — \(body.prefix(160))"
            return "Anthropic HTTP \(status)\(snippet)"
        case let .transport(msg): return "Anthropic transport: \(msg)"
        case let .decoding(msg): return "Anthropic decode: \(msg)"
        }
    }
}

/// Minimal JSON value type for the Anthropic tool input schema
/// and tool_use input fields. We only need the common shapes
/// (object with string/number/boolean properties) for the v1
/// tool set; the agent loop converts to/from `Any` when
/// serialising.
public enum AnyJSON: Codable, Sendable, Hashable {
    case nullValue
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    public var value: Any {
        switch self {
        case .nullValue: return NSNull()
        case let .bool(b): return b
        case let .int(i): return i
        case let .double(d): return d
        case let .string(s): return s
        case let .array(a): return a.map { $0.value }
        case let .object(o): return o.mapValues { $0.value }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .nullValue; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([AnyJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: AnyJSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "AnyJSON: unrecognised scalar"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .nullValue: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .int(i): try c.encode(i)
        case let .double(d): try c.encode(d)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }
}
