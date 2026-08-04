import Foundation

/// A provider the app can talk to for chat and model listing.
public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic
    case openai
    case google
    case groq
    case openrouter
    case xai
    case mistral

    public var id: String { rawValue }

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
        }
    }

    /// Whether the desktop coding agent can drive this provider today.
    public var supportsCodingAgent: Bool {
        self != .google
    }
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

    /// Stable identity across providers ("anthropic/claude-...").
    public var id: String { "\(provider.rawValue)/\(modelID)" }
}

/// Reasoning/effort level shown in the model picker's Effort row.
public enum Effort: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    public var displayName: String { rawValue.capitalized }
}
