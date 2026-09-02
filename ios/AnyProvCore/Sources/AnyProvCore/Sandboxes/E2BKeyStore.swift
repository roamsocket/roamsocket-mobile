import Foundation
import Combine

/// Local-only persistence of the user's E2B API key. The key is held
/// in memory once entered (and remembered across launches so the
/// Settings card can show "Set" / "Not set" without a round trip)
/// but is *never* synced to the desktop server — the phone uses it
/// directly to talk to e2b.dev.
public final class E2BKeyStore: ObservableObject, @unchecked Sendable {
    @Published public private(set) var hasKey: Bool
    private let key = "e2b.apiKey.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let value = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.hasKey = !value.isEmpty
    }

    public func get() -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
            hasKey = false
        } else {
            defaults.set(trimmed, forKey: key)
            hasKey = true
        }
    }

    // MARK: - Format validation

    /// Loose validator for the e2b.dev API key shape.
    ///
    /// Real keys today look like `e2b_abc123…` followed by 20+ characters
    /// of base62-ish payload. We intentionally do **not** enforce the
    /// exact length (e2b can rotate schemes) — the goal is just to
    /// catch copy-paste mistakes before saving.
    ///
    /// Returns `nil` for valid, or a short human-readable reason for
    /// invalid. Empty / nil input returns a "missing" reason so the UI
    /// can show a different message than a malformed key.
    public static func validate(_ raw: String?) -> ValidationResult {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .missing
        }
        if !trimmed.hasPrefix("e2b_") {
            return .invalid("e2b keys start with “e2b_”.")
        }
        // Strip the prefix; what's left must be reasonably long and only
        // contain characters e2b uses in API keys today (alphanumerics
        // and a small set of separators).
        let payload = trimmed.dropFirst("e2b_".count)
        if payload.count < 20 {
            return .invalid("That key is too short — paste the full string from e2b.dev.")
        }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_-"))
        if payload.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return .invalid("That key contains unexpected characters — paste it from e2b.dev without edits.")
        }
        return .valid
    }

    public enum ValidationResult: Equatable, Sendable {
        case valid
        case missing
        case invalid(String)
    }
}
