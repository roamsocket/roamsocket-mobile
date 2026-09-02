import Foundation
import AnyProvCore

/// Minimal Anthropic Messages API client. Non-streaming v1 by
/// default (`send`); streaming via `stream` returns an
/// `AsyncThrowingStream<StreamEvent>` for callers that want to
/// show text deltas as they arrive. Pinned to model
/// `claude-sonnet-4-5` with 4k max_tokens by default.
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
                    try c.encode(id, forKey: .content)
                    try c.encode(content, forKey: .text)
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
                    let id = try c.decode(String.self, forKey: .content)
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
        public let usage: Usage?

        private enum CodingKeys: String, CodingKey {
            case id, content
            case stopReason = "stop_reason"
            case usage
        }

        public struct Usage: Codable, Sendable, Hashable {
            public let inputTokens: Int
            public let outputTokens: Int
            public let cacheReadInputTokens: Int?
            public let cacheCreationInputTokens: Int?

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
            }
        }
    }

    /// One SSE event. Matches the Anthropic Messages API
    /// streaming surface. `textDelta` and `inputJsonDelta`
    /// are the per-event content deltas; `messageDelta`
    /// carries the per-turn delta for stop_reason + usage.
    public enum StreamEvent: Sendable {
        case messageStart
        case contentBlockStart(index: Int, type: String)
        case textDelta(index: Int, text: String)
        case inputJsonDelta(index: Int, partialJson: String)
        case contentBlockStop(index: Int)
        case messageDelta(stopReason: String?, usage: Response.Usage?)
        case messageStop
        case ping
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
        let (data, response) = try await post(
            system: system,
            messages: messages,
            tools: tools,
            maxTokens: maxTokens,
            stream: false,
        )
        return try Self.decode(data)
    }

    /// SSE-streaming variant of `send`. The returned `AsyncThrowingStream`
    /// yields `StreamEvent` values as the server produces them. The
    /// final event is always `.messageStop` (or an error). Caller
    /// is responsible for accumulating text deltas into a final
    /// assistant message and matching tool_use `input_json_delta`
    /// chunks back into a tool input JSON object.
    public func stream(
        system: String,
        messages: [Message],
        tools: [Tool],
        maxTokens: Int = 4096,
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        // The `build` closure of `AsyncThrowingStream.init` is
        // synchronous. The async streaming work runs in a `Task`
        // that we cancel on termination so the user can abort
        // mid-stream.
        AsyncThrowingStream<StreamEvent, Error>(
            StreamEvent.self,
            bufferingPolicy: .unbounded
        ) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await self.bytes(
                        system: system,
                        messages: messages,
                        tools: tools,
                        maxTokens: maxTokens,
                    )
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw AnthropicError.stream("Anthropic HTTP \(code)")
                    }
                    var eventName = ""
                    var dataBuffer = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty {
                            if !eventName.isEmpty {
                                let raw = dataBuffer.trimmingCharacters(in: .whitespaces)
                                if let data = raw.data(using: .utf8),
                                   let event = Self.parseSSEEvent(name: eventName, data: data) {
                                    continuation.yield(event)
                                }
                            }
                            eventName = ""
                            dataBuffer = ""
                            continue
                        }
                        if let colon = line.firstIndex(of: ":") {
                            let field = String(line[..<colon])
                            let value = String(line[line.index(after: colon)...])
                                .trimmingCharacters(in: .whitespaces)
                            if field == "event" {
                                eventName = value
                            } else if field == "data" {
                                dataBuffer = value
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Common wire-format POST. Returns either `(Data, URLResponse)`
    /// for non-streaming (caller decodes) or
    /// `(URLSession.AsyncBytes, URLResponse)` for streaming. The
    /// streaming version uses `URLSession.bytes(for:)` so the
    /// response body can be consumed incrementally.
    private func post(
        system: String,
        messages: [Message],
        tools: [Tool],
        maxTokens: Int,
        stream: Bool,
    ) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map(Self.messageToWire),
            "tools": tools.map(Self.toolToWire),
        ]
        if stream { body["stream"] = true }
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
        return (data, response)
    }

    /// Same as `post` but returns the streaming `AsyncBytes` so
    /// the caller can iterate SSE events. URLSession.bytes(for:)
    /// is the documented streaming API and gives us line-by-line
    /// iteration.
    private func bytes(
        system: String,
        messages: [Message],
        tools: [Tool],
        maxTokens: Int,
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
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
            "stream": true,
            "messages": messages.map(Self.messageToWire),
            "tools": tools.map(Self.toolToWire),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await session.bytes(for: req)
    }

    private static func decode(_ data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AnthropicError.decoding(error.localizedDescription)
        }
    }

    private static func messageToWire(_ message: Message) -> [String: Any] {
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

    private static func toolToWire(_ tool: Tool) -> [String: Any] {
        return [
            "name": tool.name,
            "description": tool.description,
            "input_schema": tool.inputSchema.value as Any,
        ]
    }

    private static func parseSSEEvent(name: String, data: Data) -> StreamEvent? {
        switch name {
        case "message_start":
            return .messageStart
        case "content_block_start":
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let index = obj["index"] as? Int,
                  let block = obj["content_block"] as? [String: Any],
                  let type = block["type"] as? String
            else { return nil }
            return .contentBlockStart(index: index, type: type)
        case "content_block_delta":
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let index = obj["index"] as? Int,
                  let delta = obj["delta"] as? [String: Any]
            else { return nil }
            if let text = delta["text"] as? String {
                return .textDelta(index: index, text: text)
            }
            if let partial = delta["partial_json"] as? String {
                return .inputJsonDelta(index: index, partialJson: partial)
            }
            return nil
        case "content_block_stop":
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let index = obj["index"] as? Int
            else { return nil }
            return .contentBlockStop(index: index)
        case "message_delta":
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let stopReason = (obj["delta"] as? [String: Any])?["stop_reason"] as? String
            let usage = (obj["usage"] as? [String: Any]).flatMap { usageDict in
                Response.Usage(
                    inputTokens: usageDict["input_tokens"] as? Int ?? 0,
                    outputTokens: usageDict["output_tokens"] as? Int ?? 0,
                    cacheReadInputTokens: usageDict["cache_read_input_tokens"] as? Int,
                    cacheCreationInputTokens: usageDict["cache_creation_input_tokens"] as? Int
                )
            }
            return .messageDelta(stopReason: stopReason, usage: usage)
        case "message_stop":
            return .messageStop
        case "ping":
            return .ping
        default:
            return nil
        }
    }
}

public enum AnthropicError: Error, LocalizedError {
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)
    case stream(String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, body):
            let snippet = body.isEmpty ? "" : " — \(body.prefix(160))"
            return "Anthropic HTTP \(status)\(snippet)"
        case let .transport(msg): return "Anthropic transport: \(msg)"
        case let .decoding(msg): return "Anthropic decode: \(msg)"
        case let .stream(msg): return "Anthropic stream: \(msg)"
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
