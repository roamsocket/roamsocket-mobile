import Foundation

/// Deep-link destinations used by App Intents, Control Center, Lock Screen,
/// Action Button, and `roamsocket://` URLs.
enum AppDeepLink: String, CaseIterable, Sendable {
    case chat
    case code
    case vision

    static let urlScheme = "roamsocket"
    static let host = "open"

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .code: return "Code"
        case .vision: return "Vision"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .vision: return "eye.fill"
        }
    }

    var url: URL {
        // roamsocket://open/chat
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = Self.host
        components.path = "/\(rawValue)"
        return components.url!
    }

    static func parse(_ url: URL) -> AppDeepLink? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == urlScheme
        else { return nil }

        // roamsocket://open/chat  OR  roamsocket://chat  OR  roamsocket:/chat
        let host = (url.host ?? "").lowercased()
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()

        if host == Self.host, let dest = AppDeepLink(rawValue: path) {
            return dest
        }
        if let dest = AppDeepLink(rawValue: host), path.isEmpty {
            return dest
        }
        if host.isEmpty, let dest = AppDeepLink(rawValue: path) {
            return dest
        }
        // Query fallback: roamsocket://?destination=vision
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "destination" })?
            .value?
            .lowercased(),
           let dest = AppDeepLink(rawValue: query)
        {
            return dest
        }
        return nil
    }
}
