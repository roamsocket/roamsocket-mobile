import Foundation

/// Secure storage for API keys and tokens. The app target provides a Keychain
/// implementation; an in-memory implementation is used for tests and previews.
public protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ value: String?, for key: String)
}

/// Well-known secret keys.
public enum SecretKey {
    public static func providerAPIKey(_ id: ProviderID) -> String { "provider.\(id.rawValue).apiKey" }
    /// Voice-only providers (e.g. ElevenLabs) that are not chat model hosts.
    public static func voiceAPIKey(_ id: String) -> String { "voice.\(id).apiKey" }
    public static let githubToken = "github.token"
    public static func serverToken(_ host: String) -> String { "server.\(host).token" }
}

/// In-memory store for tests and SwiftUI previews. Not persisted.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init(seed: [String: String] = [:]) { storage = seed }

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func set(_ value: String?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }
}
