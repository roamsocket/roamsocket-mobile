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
}
