import Foundation
import ActivityKit

/// Live Activity payload while Chat / Code / Vision is waiting on a model.
/// Shared by the app (starts/updates/ends) and the widget extension (UI).
struct AIThinkingAttributes: ActivityAttributes {
    /// Fixed for the lifetime of one activity instance.
    var kind: String
    var title: String

    /// Mutable state pushed while the model is working.
    struct ContentState: Codable, Hashable, Sendable {
        /// Short status line, e.g. "Thinking…", "Running tools…".
        var status: String
        /// Truncated user prompt for context on the Dynamic Island / Lock Screen.
        var promptPreview: String
        /// When the request started (for an elapsed-time feel).
        var startedAt: Date
    }
}

extension AIThinkingAttributes {
    enum Kind: String, Sendable {
        case chat
        case code
        case vision
        case study

        var title: String {
            switch self {
            case .chat: return "Chat"
            case .code: return "Code"
            case .vision: return "Vision"
            case .study: return "Study"
            }
        }

        var systemImage: String {
            switch self {
            case .chat: return "bubble.left.and.bubble.right.fill"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .vision: return "eye.fill"
            case .study: return "graduationcap.fill"
            }
        }

        var deepLink: AppDeepLink {
            switch self {
            case .chat: return .chat
            case .code: return .code
            case .vision: return .vision
            case .study: return .chat
            }
        }
    }
}
