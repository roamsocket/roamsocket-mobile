import Foundation

/// Errors surfaced when the user sets / clears their E2B API key from
/// outside an active coding session (Settings → E2B key). Mirrors the
/// `SkillsMCPError` shape so callers can present a consistent UI.
public enum E2BKeyError: Error, LocalizedError {
    case noServer
    case serverError(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .noServer: return "Not paired with a desktop server."
        case let .serverError(msg): return msg
        case .timeout: return "Desktop did not acknowledge the E2B key change."
        }
    }
}

/// Result of an `e2b_set_key` round trip. The desktop responds with
/// `e2b_key_ack`, which carries whether the per-connection override is
/// now active. We surface that so the Settings card can update its label
/// without a follow-up query.
public struct E2BKeyResult: Equatable, Sendable {
    public let overrideActive: Bool
    public init(overrideActive: Bool) {
        self.overrideActive = overrideActive
    }
}

/// Out-of-session client for the `e2b_set_key` round trip. The Sandboxes
/// view also has its own copy (via `SandboxesStore`) so live `e2b_log`
/// frames can be observed; this one is for the Settings-level entry
/// point that should not have to open the full Sandboxes sheet.
///
/// Each call opens a short-lived WebSocket, sends `e2b_set_key`, waits
/// for the matching `e2b_key_ack` (or an `error`), then disconnects. The
/// desktop stores the override in memory against the bearer token only,
/// so re-pairing clears it.
public final class E2BKeyClient: @unchecked Sendable {
    public init() {}

    /// Send a new override (or clear it with an empty string) and return
    /// whether the override is active.
    public func setKey(
        _ apiKey: String,
        endpoint: ServerClient.Endpoint,
        token: String,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> E2BKeyResult {
        let client = ServerClient()
        var opError: Error = E2BKeyError.timeout
        var result = E2BKeyResult(overrideActive: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        do {
            let stream = try await client.connect(endpoint: endpoint, token: token)
            try await client.send(.e2bSetKey(apiKey: apiKey))
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            for await message in stream {
                switch message {
                case let .e2bKeyAck(active):
                    result = E2BKeyResult(overrideActive: active)
                    await client.disconnect()
                    return result
                case let .error(_, text):
                    opError = E2BKeyError.serverError(
                        text.isEmpty ? "Desktop rejected the E2B key change." : text
                    )
                default:
                    break
                }
                if Date() > deadline { break }
            }
            await client.disconnect()
        } catch {
            opError = error
        }
        throw opError
    }
}
