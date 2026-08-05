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

    /// The built-in cases (excludes any `.custom(...)` synthesized values).
    public static var allBuiltInCases: [ProviderID] {
        allCases
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

/// A user-defined OpenAI- or Anthropic-style provider. Persisted alongside
/// API keys. The `id` is also the SecretKey suffix; `providerID` returns the
/// case-insensitive `ProviderID` reference the app uses to look up keys.
public struct CustomProvider: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var label: String
    public var baseURL: String

    public init(id: String, label: String, baseURL: String) {
        self.id = id
        self.label = label
        self.baseURL = baseURL
    }

    /// Style hint for the catalog: OpenAI-compatible (default) or Anthropic.
    public var style: CustomProviderStyle {
        // Detect by path: `/v1/messages` ⇒ Anthropic, `/v1/chat/completions` ⇒ OpenAI.
        if baseURL.contains("/v1/messages") { return .anthropic }
        return .openAI
    }

    public var providerID: ProviderID { .custom(id) }
}

public enum CustomProviderStyle: String, Codable, Sendable, CaseIterable {
    case openAI
    case anthropic

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        }
    }
}

extension ProviderID {
    /// Custom provider case carrying the user's slug. Excluded from
    /// `allCases` so catalog/refresh skip it; the app looks it up via
    /// `AppState.customProviders` + `providerID(for slug)`.
    public static func custom(_ slug: String) -> ProviderID {
        // We piggyback on the openai raw value with a "custom:" prefix so
        // the enum stays `RawRepresentable` + `CaseIterable` without changes
        // upstream. Decoders check `.rawValue.hasPrefix("custom:")` and
        // resolve the slug via `AppState`.
        // swiftlint:disable:next force_unwrapping
        ProviderID(rawValue: "custom:\(slug)") ?? .openai
    }

    /// Slug for `.custom(...)` providers, otherwise nil.
    public var customSlug: String? {
        guard rawValue.hasPrefix("custom:") else { return nil }
        return String(rawValue.dropFirst("custom:".count))
    }
}
