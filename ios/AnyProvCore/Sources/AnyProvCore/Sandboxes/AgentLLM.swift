import Foundation

/// Provider-agnostic LLM interface used by `E2bSessionRunner` to
/// drive the chat agent loop. Implementations are responsible
/// for talking to the upstream API (Anthropic, OpenAI, Groq,
/// OpenRouter, xAI, Mistral, custom OpenAI-compatible endpoints,
/// …) and translating the wire format into the common event
/// stream below.
///
/// All types are `Sendable` so the runner (an actor) can pass
/// events to a `@MainActor` chat view via `@Sendable` closures.
public protocol AgentLLM: Sendable {
    /// Stream a request. The returned `AsyncThrowingStream` yields
    /// events as the upstream server produces them; the final
    /// event is always `.stop` (or an error / cancellation).
    /// The runner accumulates text + tool calls and drives the
    /// agent loop; tool execution is local to the runner.
    func stream(
        system: String,
        messages: [AgentLLMMessage],
        tools: [AgentLLMTool],
        maxTokens: Int,
    ) -> AsyncThrowingStream<AgentLLMEvent, Error>
}

/// One transcript line in the provider-agnostic message array.
/// Implementations map this to the upstream wire format
/// (Anthropic `messages`, OpenAI `messages`, …).
public struct AgentLLMMessage: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable {
        case user
        case assistant
        /// "system" isn't a role in our message array — the
        /// system prompt is its own field — but we include it
        /// for the runner's ability to fold tool-output lines
        /// into the conversation as "system"-style reminders.
        case system
    }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Tool declaration in the provider-agnostic shape. The
/// `inputSchema` is a JSON Schema dict (object with
/// `type: "object"`, `properties: {...}`, `required: [...]`).
/// Both Anthropic and OpenAI accept this directly.
public struct AgentLLMTool: Sendable, Hashable {
    public let name: String
    public let description: String
    public let inputSchema: AgentLLMInputSchema

    public init(name: String, description: String, inputSchema: AgentLLMInputSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// JSON Schema for a tool's input. Lifted out of `AnyJSON` so
/// the schema can be sent as the wire format's `input_schema` /
/// `parameters` field directly. Most providers accept the same
/// shape (Anthropic, OpenAI both expect
/// `{type, properties, required}`), so a single value type
/// covers both.
public struct AgentLLMInputSchema: Sendable, Hashable, Codable {
    public let type: String
    public let properties: [String: AgentLLMProperty]
    public let required: [String]?

    public init(
        type: String = "object",
        properties: [String: AgentLLMProperty] = [:],
        required: [String]? = nil,
    ) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct AgentLLMProperty: Sendable, Hashable, Codable {
    public let type: String
    public let description: String?

    public init(type: String, description: String? = nil) {
        self.type = type
        self.description = description
    }
}

/// Events produced by an `AgentLLM.stream(...)` call. The
/// runner accumulates these into the final assistant turn
/// (text + tool calls) and the running usage total.
public enum AgentLLMEvent: Sendable {
    /// Incremental text delta from the model. Several of these
    /// in a row compose the full assistant turn text.
    case textDelta(text: String)
    /// A new tool_use block has started. `input` is the
    /// currently-known input (often empty at start; the rest
    /// comes through `toolCallInputDelta`).
    case toolCallStart(id: String, name: String, input: AgentLLMInput)
    /// A chunk of the tool-use input JSON. Concatenated across
    /// `toolCallStart` → multiple deltas → `toolCallEnd` to
    /// produce the final `AgentLLMInput`.
    case toolCallInputDelta(id: String, partialJSON: String)
    /// The current tool-call's input has finished streaming.
    case toolCallEnd(id: String)
    /// Per-turn token usage (cumulative for the response).
    case usage(inputTokens: Int, outputTokens: Int)
    /// The upstream finished its response.
    case stop
}

/// Parsed tool input. We keep both the raw `AnyJSON` (so the
/// runner can pass it through to the tool implementation) and
/// a tiny set of accessors the runner uses for summaries.
public struct AgentLLMInput: Sendable, Hashable {
    public let raw: AnyJSON

    public init(raw: AnyJSON) {
        self.raw = raw
    }

    public func stringValue(for key: String) -> String? {
        guard case let .object(dict) = raw else { return nil }
        guard case let .string(s) = dict[key] else { return nil }
        return s
    }

    public func boolValue(for key: String) -> Bool? {
        guard case let .object(dict) = raw else { return nil }
        guard case let .bool(b) = dict[key] else { return nil }
        return b
    }

    public func intValue(for key: String) -> Int? {
        guard case let .object(dict) = raw else { return nil }
        guard case let .int(i) = dict[key] else { return nil }
        return i
    }
}

/// Picks the right `AgentLLM` implementation for a given
/// provider. Today: Anthropic for `.anthropic`, OpenAI-compatible
/// for everything else (OpenAI, Groq, OpenRouter, xAI, Mistral,
/// custom). Local-only providers (`.localMetal`, `.appleFoundation`)
/// and Google (`google`) are not yet wired — they need their own
/// client because the request shape differs.
public enum AgentLLMFactory {
    public static func make(
        provider: ProviderID,
        modelID: String,
        apiKey: String,
        baseURL: URL? = nil,
        maxTokens: Int = 4096,
    ) throws -> AgentLLM {
        switch provider {
        case .anthropic:
            return AnthropicAgentLLM(
                apiKey: apiKey,
                modelID: modelID,
                maxTokens: maxTokens
            )
        case .openai, .groq, .openrouter, .xai, .mistral, .minimax, .custom:
            return OpenAICompatibleAgentLLM(
                apiKey: apiKey,
                modelID: modelID,
                baseURL: baseURL ?? Self.defaultBaseURL(for: provider),
                maxTokens: maxTokens,
                useNonStreaming: Self.prefersNonStreaming(for: provider)
            )
        case .google, .localMetal, .appleFoundation:
            throw AgentLLMError.unsupportedProvider(provider.rawValue)
        }
    }

    /// Whether the OpenAI-compatible agent for this provider
    /// should issue a one-shot POST instead of an SSE stream.
    /// MiniMax's streaming endpoint accepts the request but
    /// returns an empty body when `tools` is set, leaving the
    /// E2B agent pinned at "Working" — the desktop server's
    /// E2B runner and the iOS chat composer both use the
    /// non-streaming path for the same reason. Future providers
    /// with the same shape can be added here.
    private static func prefersNonStreaming(for provider: ProviderID) -> Bool {
        switch provider {
        case .minimax: return true
        default: return false
        }
    }

    /// Default base URL for OpenAI-compatible providers. Custom
    /// endpoints must supply their own `baseURL`. Each entry
    /// mirrors `OpenAICompatibleProvider.defaultBaseURL(for:)`
    /// so the chat path and the E2B agent loop talk to the same
    /// upstream for a given provider — drift here was the cause
    /// of the MiniMax 401 (the agent's `default` arm pointed at
    /// `api.openai.com`).
    private static func defaultBaseURL(for provider: ProviderID) -> URL {
        switch provider {
        case .openai: return URL(string: "https://api.openai.com")!
        case .groq: return URL(string: "https://api.groq.com/openai")!
        case .openrouter: return URL(string: "https://openrouter.ai/api")!
        case .xai: return URL(string: "https://api.x.ai")!
        case .mistral: return URL(string: "https://api.mistral.ai")!
        case .minimax: return URL(string: "https://api.minimax.io")!
        default: return URL(string: "https://api.openai.com")!
        }
    }
}

public enum AgentLLMError: Error, LocalizedError {
    case unsupportedProvider(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(name):
            return "Provider '\(name)' isn't wired into the E2B agent yet. Switch to Anthropic or an OpenAI-compatible model."
        }
    }
}
