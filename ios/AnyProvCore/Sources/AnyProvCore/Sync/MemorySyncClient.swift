import Foundation
import Combine

/// Errors emitted by memory sync over WebSocket.
public enum MemorySyncError: Error, LocalizedError {
    case noServer
    case serverError(String)
    case decodeFailure

    public var errorDescription: String? {
        switch self {
        case .noServer: return "Not paired with a desktop server."
        case let .serverError(msg): return msg
        case .decodeFailure: return "Server returned malformed data."
        }
    }
}

/// iOS client for memory sync. Git work runs on the paired desktop
/// (filesystem + `git`); this type sends upsert/delete/sync over
/// WebSocket and surfaces server errors.
///
/// Local JSON cache holds the latest synced state for offline viewing;
/// edits go through `ServerClient.send(...)` with the memory messages.
public final class MemorySyncClient: ObservableObject, @unchecked Sendable {
    @Published public private(set) var lastSyncError: String?

    /// Local cache of memory entries (mirrors the last `memory_sync` from desktop).
    @Published public private(set) var cachedEntries: [MemoryEntryPayload] = []

    private let cacheKey = "memorySync.cache.v1"

    public init() {
        loadCache()
    }

    public func handleServerMessage(_ message: ServerMessage) {
        switch message {
        case let .memorySync(entries):
            cachedEntries = entries
            saveCache()
        default:
            break
        }
    }

    // MARK: - Outgoing ops (self-connecting)

    /// Ask the desktop to pull + push the configured memory repo and resync.
    public func requestMemorySync(
        endpoint: ServerClient.Endpoint,
        token: String
    ) async throws {
        try await performOp(.memorySyncRequest, endpoint: endpoint, token: token)
    }

    /// Upsert a memory entry via the desktop. The server replies with a
    /// fresh `memory_sync` that we apply to the local cache (and the
    /// caller applies to `UserMemoryStore`). The local cache is updated
    /// eagerly so the list reflects the change immediately.
    public func upsertEntry(
        _ entry: MemoryEntryPayload,
        endpoint: ServerClient.Endpoint,
        token: String
    ) async throws {
        if let idx = cachedEntries.firstIndex(where: { $0.id == entry.id }) {
            cachedEntries[idx] = entry
        } else {
            cachedEntries.insert(entry, at: 0)
        }
        saveCache()
        try await performOp(.memoryUpsert(entry: entry), endpoint: endpoint, token: token)
    }

    /// Delete a memory entry via the desktop. Local cache is updated eagerly.
    public func deleteEntry(
        id: String,
        endpoint: ServerClient.Endpoint,
        token: String
    ) async throws {
        cachedEntries.removeAll { $0.id == id }
        saveCache()
        try await performOp(.memoryDelete(id: id), endpoint: endpoint, token: token)
    }

    /// Ask the desktop for the canonical state and refresh the local
    /// cache. Used when entering Settings / Memory so the user always
    /// sees the most up-to-date list. Errors (e.g. no repo configured)
    /// are surfaced via `lastSyncError`, not thrown.
    public func refreshAll(
        endpoint: ServerClient.Endpoint,
        token: String,
        timeoutSeconds: TimeInterval = 10
    ) async {
        lastSyncError = nil
        do {
            try await requestMemorySync(endpoint: endpoint, token: token)
        } catch {
            lastSyncError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// The app's long-lived socket only exists inside a coding session,
    /// so every memory op opens its own short-lived connection, waits
    /// for the desktop's acknowledging sync (or error), then tears down.
    private func performOp(
        _ request: ClientMessage,
        endpoint: ServerClient.Endpoint,
        token: String,
        timeoutSeconds: TimeInterval = 15
    ) async throws {
        let client = ServerClient()
        var opError: Error = MemorySyncError.serverError("Desktop did not acknowledge the request.")
        do {
            let stream = try await client.connect(endpoint: endpoint, token: token)
            try await client.send(request)
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            for await message in stream {
                switch message {
                case .memorySync:
                    handleServerMessage(message)
                    await client.disconnect()
                    return
                case let .error(_, text):
                    opError = MemorySyncError.serverError(
                        text.isEmpty ? "Desktop sync failed." : text
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

    // MARK: - Local cache (offline view)

    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([MemoryEntryPayload].self, from: data) {
            cachedEntries = decoded
        }
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(cachedEntries) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}
