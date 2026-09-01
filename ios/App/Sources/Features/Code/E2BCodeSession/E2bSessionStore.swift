import Foundation
import Combine
import AnyProvCore

/// Owns the E2B code sessions for the iOS app: opening a new
/// session (creates a sandbox via `DirectE2BClient`), appending
/// transcript messages, persisting to disk, and killing
/// sandboxes on close.
///
/// Sessions persist to `Application Support/e2bCodeSessions.v1.json`
/// so the user can re-open a session after a relaunch. While a
/// session is "live" (has a sandboxId) we keep the live state
/// in memory; the on-disk snapshot is the source of truth across
/// launches.
///
/// The agent loop (LLM calls, tool dispatch) is wired in
/// separately via `E2bSessionRunner` — this store just owns the
/// data + sandbox lifecycle.
@MainActor
final class E2bSessionStore: ObservableObject {
    @Published private(set) var sessions: [E2bCodeSession] = []

    private let client: DirectE2BClient?
    private let apiKey: String?
    private let persistence: E2bSessionPersistence

    init(apiKey: String? = nil) {
        self.apiKey = apiKey
        self.client = apiKey.map { DirectE2BClient(apiKey: $0) }
        self.persistence = E2bSessionPersistence()
        self.sessions = persistence.load().map { Self.normaliseOnLoad($0) }
    }

    // MARK: - Session lifecycle

    /// Open a new E2B code session: pick a repo + branch, create
    /// the sandbox, persist the live state. Returns the session
    /// id when the sandbox is ready (or in flight).
    @discardableResult
    func openSession(
        title: String,
        repoFullName: String,
        branch: String,
    ) async throws -> UUID {
        guard let client else {
            throw E2BSessionError.noApiKey
        }
        // 1. Persist a placeholder row so the UI can render the
        //    "provisioning" state immediately.
        let session = E2bCodeSession(
            title: title,
            repoFullName: repoFullName,
            branch: branch,
            status: .provisioning,
        )
        upsert(session)

        // 2. Provision the sandbox.
        do {
            let info = try await client.createSandbox()
            var live = session
            live.sandboxId = info.sandboxId
            live.sandboxAccessToken = info.accessToken
            live.sandboxUrl = live.liveSandboxURL
            live.status = .idle
            live.updatedAt = Date()
            upsert(live)
            return live.id
        } catch {
            var failed = session
            failed.status = .failed
            failed.transcript.append(.init(
                kind: .notice,
                text: "Failed to provision sandbox: \(error.localizedDescription)"
            ))
            failed.updatedAt = Date()
            upsert(failed)
            throw error
        }
    }

    /// Append a message to a session's transcript. Cheap —
    /// triggers a debounced disk write via the store.
    func appendMessage(sessionId: UUID, _ message: E2bCodeMessage) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].transcript.append(message)
        sessions[idx].updatedAt = Date()
        persist()
    }

    /// Kill the sandbox backing a session. Marks the session
    /// as `.killed` so the UI shows the closed state. No-op if
    /// the session is already killed or has no live sandbox.
    func closeSession(_ sessionId: UUID) async {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let sandboxId = sessions[idx].sandboxId
        let accessToken = sessions[idx].sandboxAccessToken
        if let client, let sandboxId, !sandboxId.isEmpty {
            await client.killSandbox(sandboxId: sandboxId)
        }
        sessions[idx].sandboxId = nil
        sessions[idx].sandboxAccessToken = nil
        sessions[idx].sandboxUrl = nil
        sessions[idx].status = .killed
        sessions[idx].agentActive = false
        sessions[idx].updatedAt = Date()
        persist()
        _ = accessToken
    }

    func session(id: UUID) -> E2bCodeSession? {
        sessions.first { $0.id == id }
    }

    /// Update the live-sandbox fields on an existing session. Used
    /// when reopening a closed session on a fresh sandbox.
    func attachSandbox(
        sessionId: UUID,
        sandboxId: String,
        accessToken: String?,
        domain: String,
    ) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].sandboxId = sandboxId
        sessions[idx].sandboxAccessToken = accessToken
        sessions[idx].sandboxDomain = domain
        sessions[idx].sandboxUrl = sessions[idx].liveSandboxURL
        sessions[idx].status = .idle
        sessions[idx].updatedAt = Date()
        persist()
    }

    /// Update the session's lifecycle status. The chat view
    /// drives this: `.working` when a turn starts, `.idle` when
    /// it ends (or `.failed` on a hard error). The Code home
    /// reads `status` to render the right pill on the session
    /// row.
    func setStatus(_ sessionId: UUID, _ status: E2bCodeSession.Status) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        // Only persist on a real transition — the runner flips
        // this on every step.
        guard sessions[idx].status != status else { return }
        sessions[idx].status = status
        sessions[idx].updatedAt = Date()
        persist()
    }

    // MARK: - Internal

    private func upsert(_ session: E2bCodeSession) {
        let now = Date()
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
            sessions[idx].updatedAt = now
        } else {
            var inserted = session
            inserted.updatedAt = now
            sessions.insert(inserted, at: 0)
        }
        persist()
    }

    private func persist() {
        persistence.save(sessions)
    }

    /// On reload, "stuck" provisioning / working sessions are
    /// dead (the sandbox is gone after a relaunch). Mark them
    /// as killed so the user knows the session is closed.
    private static func normaliseOnLoad(_ session: E2bCodeSession) -> E2bCodeSession {
        var copy = session
        switch copy.status {
        case .provisioning, .working:
            copy.status = .killed
            copy.agentActive = false
        default:
            break
        }
        return copy
    }
}

enum E2BSessionError: Error, LocalizedError {
    case noApiKey

    var errorDescription: String? {
        switch self {
        case .noApiKey: return "Add your e2b.dev API key in Settings first."
        }
    }
}

// MARK: - Persistence

/// Tiny JSON-on-disk store for sessions. Mirrors the shape of
/// `PhoneRunPersistence` but for the longer-lived code-session
/// model. One file under `Application Support`, debounced writes.
private final class E2bSessionPersistence {
    private let fileURL: URL
    private var debounceTask: Task<Void, Never>?
    private var pendingSnapshot: [E2bCodeSession]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultFileURL()
        }
    }

    func load() -> [E2bCodeSession] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([E2bCodeSession].self, from: data)) ?? []
    }

    func save(_ sessions: [E2bCodeSession]) {
        pendingSnapshot = sessions
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.flushPending()
        }
    }

    func flushNow() {
        debounceTask?.cancel()
        debounceTask = nil
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        do {
            try write(snapshot)
        } catch {
            // best-effort
        }
    }

    private func flushPending() async {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        do {
            try write(snapshot)
        } catch {
            // best-effort
        }
    }

    private func write(_ sessions: [E2bCodeSession]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sessions)
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("e2bCodeSessions.v1.json")
    }
}
