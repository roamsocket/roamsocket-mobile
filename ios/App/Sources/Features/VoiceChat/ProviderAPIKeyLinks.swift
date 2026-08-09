import Foundation
import AnyProvCore

/// Deep links to each provider’s “create / manage API keys” page in the browser.
enum ProviderAPIKeyLinks {
    static func url(for provider: ProviderID) -> URL? {
        switch provider {
        case .anthropic:
            return URL(string: "https://console.anthropic.com/settings/keys")
        case .openai:
            return URL(string: "https://platform.openai.com/api-keys")
        case .google:
            return URL(string: "https://aistudio.google.com/apikey")
        case .groq:
            return URL(string: "https://console.groq.com/keys")
        case .openrouter:
            return URL(string: "https://openrouter.ai/settings/keys")
        case .xai:
            return URL(string: "https://console.x.ai/")
        case .mistral:
            return URL(string: "https://console.mistral.ai/api-keys")
        case .minimax:
            return URL(string: "https://platform.minimax.io/user-center/basic-information/interface-key")
        case .localMetal, .appleFoundation, .custom:
            return nil
        }
    }

    /// Voice-only providers (not in `ProviderID`).
    static func voiceProviderURL(id: String) -> URL? {
        switch id {
        case VoiceSettingsStore.elevenLabsVoiceKeyID, "elevenlabs":
            return URL(string: "https://elevenlabs.io/app/settings/api-keys")
        default:
            return nil
        }
    }

    static let openAITTSDocs = URL(string: "https://platform.openai.com/docs/guides/text-to-speech")
    static let elevenLabsDocs = URL(string: "https://elevenlabs.io/docs/api-reference/text-to-speech")
}
