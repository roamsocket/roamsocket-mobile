import Foundation

/// A provider the app can talk to for chat and model listing.
///
/// Built-in cases cover the providers the desktop agent loop understands.
/// `.custom(slug)` lets users add their own OpenAI-compatible endpoint; the
/// slug is the user-chosen id (also the SecretKey suffix and the wire-format
/// `custom:<slug>` string).
public enum ProviderID: Hashable, Sendable, Identifiable {
    case anthropic
    case openai
    case google
    case groq
    case openrouter
    case xai
    case mistral
    /// A user-defined OpenAI-compatible provider. `slug` is the stable id.
    case custom(String)

    public var id: String {
        switch self {
        case .custom(let slug): return "custom:\(slug)"
        default: return rawValue
        }
    }

    /// The on-the-wire `provider` string used in `ModelSelection`. Built-in
    /// providers use their short raw value; custom providers use `custom:<slug>`.
    public var rawValue: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        case .google: return "google"
        case .groq: return "groq"
        case .openrouter: return "openrouter"
        case .xai: return "xai"
        case .mistral: return "mistral"
        case .custom(let slug): return "custom:\(slug)"
        }
    }

    /// True for built-in providers with a hardcoded base URL.
    public var isBuiltIn: Bool {
        if case .custom = self { return false }
        return true
    }

    /// Human-readable provider name for the UI.
    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .google: return "Google Gemini"
        case .groq: return "Groq"
        case .openrouter: return "OpenRouter"
        case .xai: return "xAI"
        case .mistral: return "Mistral"
        case .custom: return "Custom" // Resolve via `displayName(for label:)` in UI code.
        }
    }

    /// Whether the desktop coding agent can drive this provider today.
    public var supportsCodingAgent: Bool {
        switch self {
        case .google: return false
        case .anthropic, .openai, .groq, .openrouter, .xai, .mistral: return true
        case .custom: return true // assumed OpenAI-compatible; the server will validate.
        }
    }

    /// The short slug for a custom provider, if this is one.
    public var customSlug: String? {
        if case .custom(let slug) = self { return slug }
        return nil
    }
}

extension ProviderID: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "anthropic": self = .anthropic
        case "openai": self = .openai
        case "google": self = .google
        case "groq": self = .groq
        case "openrouter": self = .openrouter
        case "xai": self = .xai
        case "mistral": self = .mistral
        default:
            // Accept "custom:<slug>" as well as legacy bare slugs for safety.
            if raw.hasPrefix("custom:") {
                let slug = String(raw.dropFirst("custom:".count))
                guard !slug.isEmpty else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Empty custom provider slug"))
                }
                self = .custom(slug)
            } else {
                self = .custom(raw)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension ProviderID: CaseIterable {
    public static var allBuiltInCases: [ProviderID] {
        [.anthropic, .openai, .google, .groq, .openrouter, .xai, .mistral]
    }

    /// Built-in cases for iteration in UI. Custom providers are surfaced
    /// separately via `AppState.customProviders`.
    public static var allCases: [ProviderID] { allBuiltInCases }
}

extension ProviderID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// A single model exposed by a provider.
public struct AIModel: Codable, Hashable, Sendable, Identifiable {
    public let provider: ProviderID
    /// Provider-native model id, e.g. "claude-sonnet-4" or "gpt-4o".
    public let modelID: String
    public let displayName: String
    public let contextWindow: Int?

    public init(provider: ProviderID, modelID: String, displayName: String, contextWindow: Int? = nil) {
        self.provider = provider
        self.modelID = modelID
        self.displayName = displayName
        self.contextWindow = contextWindow
    }

    /// Stable identity across providers ("anthropic/claude-..." or
    /// "custom:my-proxy/llama-3.3-70b").
    public var id: String { "\(provider.rawValue)/\(modelID)" }
}

/// Reasoning/effort level shown in the model picker's Effort row.
public enum Effort: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    public var displayName: String { rawValue.capitalized }
}

/// A user-defined OpenAI-compatible provider. Persisted alongside API keys.
public struct CustomProvider: Codable, Hashable, Sendable, Identifiable {
    /// Stable identifier (also the SecretKey suffix). Lowercased, no spaces.
    public var id: String
    /// Human-readable label shown in the UI.
    public var label: String
    /// Base URL for the OpenAI-compatible API (e.g. `https://llm.example.com/v1`).
    public var baseURL: String

    public init(id: String, label: String, baseURL: String) {
        self.id = id
        self.label = label
        self.baseURL = baseURL
    }

    public var providerID: ProviderID { .custom(id) }
}
