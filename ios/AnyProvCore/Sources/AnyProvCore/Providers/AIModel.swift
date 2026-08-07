import Foundation

/// A provider the app can talk to for chat and model listing.
///
/// Built-in providers use fixed cases. User-defined endpoints use
/// `.custom(slug)` and encode as `"custom:<slug>"` so they never collide with
/// OpenAI / Anthropic / etc.
public enum ProviderID: Hashable, Sendable, Identifiable, Codable {
    case anthropic
    case openai
    case google
    case groq
    case openrouter
    case xai
    case mistral
    /// Metal (MLX). Phone weights are chat-only; **desktop-installed** Metal
    /// models (listed via `GET /metal/models`) can drive coding sessions.
    case localMetal
    /// Apple on-device Foundation Model (Apple Intelligence) — **chat only**.
    case appleFoundation
    case custom(String)

    public var id: String { rawValue }

    /// Wire / Keychain string form.
    public var rawValue: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        case .google: return "google"
        case .groq: return "groq"
        case .openrouter: return "openrouter"
        case .xai: return "xai"
        case .mistral: return "mistral"
        case .localMetal: return "local-metal"
        case .appleFoundation: return "apple-foundation"
        case .custom(let slug): return "custom:\(slug)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "anthropic": self = .anthropic
        case "openai": self = .openai
        case "google": self = .google
        case "groq": self = .groq
        case "openrouter": self = .openrouter
        case "xai": self = .xai
        case "mistral": self = .mistral
        case "local-metal", "localMetal", "local", "metal": self = .localMetal
        case "apple-foundation", "apple", "foundation-models", "apple-intelligence":
            self = .appleFoundation
        default:
            guard rawValue.hasPrefix("custom:") else { return nil }
            let slug = String(rawValue.dropFirst("custom:".count))
            guard !slug.isEmpty else { return nil }
            self = .custom(slug)
        }
    }

    /// Built-in providers only (excludes user-defined `.custom`).
    public static var allBuiltInCases: [ProviderID] {
        [.anthropic, .openai, .google, .groq, .openrouter, .xai, .mistral, .localMetal, .appleFoundation]
    }

    /// Alias used by settings UIs that list first-party providers.
    public static var allCases: [ProviderID] { allBuiltInCases }

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
        case .localMetal: return "On-device (Metal)"
        case .appleFoundation: return "Apple Intelligence"
        case .custom(let slug): return slug
        }
    }

    /// Whether the desktop coding agent can drive this provider today.
    /// Phone Metal / Apple Intelligence remain chat-only on-device; desktop Metal
    /// (`localMetal`) is supported when the model is installed on the server.
    public var supportsCodingAgent: Bool {
        switch self {
        case .google, .appleFoundation: return false
        default: return true
        }
    }

    /// Cloud API key required for network providers.
    public var requiresAPIKey: Bool {
        switch self {
        case .localMetal, .appleFoundation: return false
        default: return true
        }
    }

    /// Slug for `.custom(...)` providers, otherwise nil.
    public var customSlug: String? {
        if case .custom(let slug) = self { return slug }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = ProviderID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown provider id: \(raw)"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A single model exposed by a provider.
public struct AIModel: Codable, Hashable, Sendable, Identifiable {
    public let provider: ProviderID
    /// Provider-native model id, e.g. "gpt-4o" or "gemini-2.0-flash".
    public let modelID: String
    public let displayName: String
    public let contextWindow: Int?

    public init(provider: ProviderID, modelID: String, displayName: String, contextWindow: Int? = nil) {
        self.provider = provider
        self.modelID = modelID
        self.displayName = displayName
        self.contextWindow = contextWindow
    }

    /// Stable identity across providers ("anthropic/…", "openai/…").
    public var id: String { "\(provider.rawValue)/\(modelID)" }
}

/// Reasoning/effort level shown in the model picker's Effort row.
public enum Effort: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    public var displayName: String { rawValue.capitalized }

    /// Short label under the slider (Claude-style).
    public var summary: String {
        switch self {
        case .low: return "Faster replies"
        case .medium: return "Balanced"
        case .high: return "Thorough reasoning"
        }
    }

    /// Longer explanation shown beside / under the selected effort.
    public var detail: String {
        switch self {
        case .low:
            return "Minimal deliberation. Best for quick questions, simple edits, and when latency matters more than depth."
        case .medium:
            return "Solid default for everyday coding and chat. Weighs trade-offs without spending a long time planning."
        case .high:
            return "More careful multi-step reasoning. Prefer for hard bugs, architecture, refactors, and tasks with many tools."
        }
    }

    /// Slider index 0…2
    public var sliderIndex: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func from(sliderIndex: Int) -> Effort {
        switch sliderIndex {
        case 0: return .low
        case 1: return .medium
        default: return .high
        }
    }
}

/// HTTP shape used for listing models and chat completions.
public enum CustomProviderStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// OpenAI Chat Completions: `GET {base}/models`, `POST {base}/chat/completions`
    case openAI = "openai"
    /// Anthropic Messages: `GET {base}/models`, `POST {base}/messages`
    case anthropic = "anthropic"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI-compatible"
        case .anthropic: return "Anthropic Messages"
        }
    }

    public var detail: String {
        switch self {
        case .openAI:
            return "POST {base}/chat/completions · GET {base}/models · Bearer auth"
        case .anthropic:
            return "POST {base}/messages · GET {base}/models · x-api-key auth"
        }
    }
}

/// A user-defined provider endpoint. Persisted in UserDefaults; API keys use
/// Keychain via `providerID` (`custom:<id>`).
public struct CustomProvider: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var label: String
    /// Base URL including the version segment, e.g. `https://host/v1`.
    /// Do not include `/chat/completions` or `/messages`.
    public var baseURL: String
    public var style: CustomProviderStyle
    /// When true, models from this provider are treated as vision-capable
    /// (unless the model id is clearly non-vision, e.g. embeddings / TTS).
    public var supportsVision: Bool

    public init(
        id: String,
        label: String,
        baseURL: String,
        style: CustomProviderStyle = .openAI,
        supportsVision: Bool = false
    ) {
        self.id = id
        self.label = label
        self.baseURL = baseURL
        self.style = style
        self.supportsVision = supportsVision
    }

    public var providerID: ProviderID { .custom(id) }

    enum CodingKeys: String, CodingKey {
        case id, label, baseURL, style, supportsVision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        // Older installs only stored OpenAI-compatible customs.
        style = try c.decodeIfPresent(CustomProviderStyle.self, forKey: .style) ?? .openAI
        supportsVision = try c.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false
    }
}
