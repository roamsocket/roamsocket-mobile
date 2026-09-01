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
    /// the sandbox, clone the repo into /code, persist the live
    /// state. Returns the session id when the sandbox is ready
    /// (or in flight).
    ///
    /// `githubToken` is optional. When supplied we use it for
    /// `git clone` so private repos work; for public repos it's
    /// ignored.
    @discardableResult
    func openSession(
        title: String,
        repoFullName: String,
        branch: String,
        modelID: String = "claude-sonnet-4-5",
        githubToken: String? = nil,
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
            modelID: modelID,
        )
        upsert(session)

        // 2. Provision the sandbox.
        let info: E2bSandboxInfo
        do {
            info = try await client.createSandbox()
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
        var live = session
        live.sandboxId = info.sandboxId
        live.sandboxAccessToken = info.accessToken
        live.sandboxUrl = live.liveSandboxURL
        live.status = .idle
        live.updatedAt = Date()
        upsert(live)

        // 3. Pre-clone the repo into /code so the agent doesn't
        //    burn its first turn running git. We do this after
        //    persisting the live state so the user sees the
        //    sandbox come online even if the clone fails. A
        //    failed clone lands as a transcript notice.
        do {
            try await preCloneRepo(
                e2b: client,
                sessionId: live.id,
                sandboxId: info.sandboxId,
                accessToken: info.accessToken,
                repoFullName: repoFullName,
                branch: branch,
                githubToken: githubToken
            )
        } catch {
            appendMessage(
                sessionId: live.id,
                .init(
                    kind: .notice,
                    text: "Sandbox is up but the repo clone failed: \(error.localizedDescription). The agent can run `git clone` itself."
                )
            )
        }
        return live.id
    }

    /// Pre-clone `repoFullName` into /code and check out
    /// `branch`. Injects the user's GitHub token into the
    /// clone URL when supplied so private repos work. Designed
    /// to be best-effort: a failure here is reported as a
    /// transcript notice, not a session error, because the
    /// agent can always `git clone` itself.
    private func preCloneRepo(
        e2b: DirectE2BClient,
        sessionId: UUID,
        sandboxId: String,
        accessToken: String?,
        repoFullName: String,
        branch: String,
        githubToken: String?,
    ) async throws {
        let token = githubToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cloneURL: String
        if token.isEmpty {
            cloneURL = "https://github.com/\(repoFullName).git"
        } else {
            cloneURL = "https://oauth2:\(token)@github.com/\(repoFullName).git"
        }
        // Build the Python that does the clone + checkout.
        // Output is JSON so we can detect errors.
        let script = """
        import subprocess, json
        clone_url = \(Self.escapePython(cloneURL))
        branch = \(Self.escapePython(branch))
        try:
            clone = subprocess.run(
                ["git", "clone", "--depth", "1", clone_url, "/code"],
                capture_output=True, text=True, timeout=120,
            )
            if clone.returncode != 0:
                print(json.dumps({"ok": False, "step": "clone", "stderr": clone.stderr}))
                return
            # Try to switch to the requested branch; depth-1
            # clone may not have it.
            subprocess.run(
                ["git", "fetch", "--depth", "1", "origin", branch],
                cwd="/code", capture_output=True, text=True, timeout=60,
            )
            co = subprocess.run(
                ["git", "checkout", branch],
                cwd="/code", capture_output=True, text=True, timeout=60,
            )
            if co.returncode != 0:
                print(json.dumps({"ok": False, "step": "checkout", "stderr": co.stderr}))
                return
            sha = subprocess.run(
                ["git", "rev-parse", "--short", "HEAD"],
                cwd="/code", capture_output=True, text=True, timeout=10,
            )
            print(json.dumps({"ok": True, "sha": sha.stdout.strip()}))
        except Exception as exc:
            print(json.dumps({"ok": False, "step": "exception", "stderr": str(exc)}))
        """
        let raw = try await e2b.exec(
            sandboxId: sandboxId,
            accessToken: accessToken,
            code: script,
            timeoutMs: 180_000,
        )
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw DirectE2BError.stream("pre-clone: invalid response — \(raw.prefix(200))")
        }
        if let ok = parsed["ok"] as? Bool, ok {
            let sha = parsed["sha"] as? String ?? "?"
            appendMessage(
                sessionId: sessionId,
                .init(
                    kind: .notice,
                    text: "Pre-cloned \(repoFullName)@\(branch) → \(sha)"
                )
            )
            return
        }
        let step = parsed["step"] as? String ?? "unknown"
        let stderr = parsed["stderr"] as? String ?? raw
        throw NSError(
            domain: "E2BSessionPreClone",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "pre-clone failed at \(step): \(stderr.prefix(400))"]
        )
    }

    private static func escapePython(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
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

    /// Stamp the model id onto a session. Captured at first
    /// turn so subsequent cost estimates don't drift when the
    /// user changes the selected model elsewhere.
    func setModelID(_ sessionId: UUID, modelID: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard sessions[idx].modelID != modelID else { return }
        sessions[idx].modelID = modelID
        sessions[idx].updatedAt = Date()
        persist()
    }

    /// Accumulate the per-step token usage into the session's
    /// running total. Called by the runner after each Claude
    /// response. The session's `updatedAt` is bumped so the
    /// chat view re-renders the cost footer.
    func recordUsage(
        sessionId: UUID,
        inputTokens: Int,
        outputTokens: Int,
    ) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].totalInputTokens += inputTokens
        sessions[idx].totalOutputTokens += outputTokens
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
