import Foundation
import Combine
import AnyProvCore

/// Owns the Sandboxes sheet's WebSocket + run registry. Mirrors the
/// `SandboxesView` 1:1; we keep it out of the view so the `ForEach`
/// diffing doesn't churn on every log line.
@MainActor
final class SandboxesStore: ObservableObject {
    @Published private(set) var runs: [E2bRunPayload] = []
    @Published private(set) var hasUserKey: Bool = false
    @Published private(set) var isReady: Bool = false
    @Published private(set) var lastStatusLabel: String?
    /// Phone-originated runs (no paired desktop required). Merged into
    /// the unified list shown in [SandboxesView] alongside the desktop
    /// runs, with a "phone" badge to distinguish them. Persisted to
    /// disk via [PhoneRunPersistence] so the history survives launches.
    @Published private(set) var phoneRuns: [E2bPhoneRun] = []

    /// Errors surfaced from the connection itself (handshake failure,
    /// send failure). One-shot — the view shows them in an alert.
    let errors = PassthroughSubject<String?, Never>()

    private let client = ServerClient()
    private var task: Task<Void, Never>?
    /// In-flight phone-originated runs. Used so the view's "Stop"
    /// button can cancel the orchestrating `Task`. We also reach
    /// into this on `deinit` to cancel anything still running so
    /// the run loops don't outlive the store.
    private var phoneRunTasks: [String: Task<Void, Never>] = [:]
    private let phonePersistence = PhoneRunPersistence()

    init() {
        // Hydrate from disk so the history survives launches. Only
        // pull terminal runs back — anything still "running" or
        // "queued" when the app died is dead now (the sandbox is
        // gone) and we mark it so for clarity.
        let loaded = phonePersistence.load()
        phoneRuns = loaded.map { run in
            guard run.status == "running" || run.status == "queued" else { return run }
            var copy = run
            copy.status = "killed"
            copy.error = "App was closed before the run finished."
            copy.finishedAt = copy.finishedAt ?? Date().timeIntervalSince1970 * 1000
            return copy
        }
        // Re-persist the normalized state so the disk matches.
        if phoneRuns != loaded { persistPhoneRuns() }
    }

    func start(endpoint: ServerClient.Endpoint?, token: String?) async {
        guard let endpoint, let token else {
            errors.send("Pair a desktop server first.")
            return
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await client.connect(endpoint: endpoint, token: token)
                await MainActor.run { self.isReady = true }
                // Request the existing run history up front.
                try await client.send(.e2bList(sessionId: nil, limit: 50))
                for await msg in stream {
                    await MainActor.run { self.handle(msg) }
                }
            } catch {
                await MainActor.run {
                    self.isReady = false
                    self.errors.send((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        // Cancel any in-flight phone runs so the run loops don't
        // outlive the view. The cancellation flows through
        // `DirectE2BClient.run` and lands the row as `killed`.
        for (_, runTask) in phoneRunTasks {
            runTask.cancel()
        }
        phoneRunTasks.removeAll()
        // Flush the debounced phone-run write so the very last
        // mutation isn't lost on background.
        phonePersistence.flushNow()
        // `ServerClient` is an `actor`; tear it down off the MainActor.
        // Capturing `client` keeps the reference alive across the hop.
        let client = self.client
        Task.detached { await client.disconnect() }
        isReady = false
    }

    func setKey(_ key: String) async {
        do {
            try await client.send(.e2bSetKey(apiKey: key))
        } catch {
            errors.send((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func abort(runId: String) async {
        // Phone-originated runs are cancelled locally — there's no
        // desktop to ask. The cancel flows through DirectE2BClient
        // and lands the row as `killed`.
        if phoneRunTasks[runId] != nil {
            cancelPhoneRun(runId: runId)
            return
        }
        do {
            try await client.send(.e2bAbort(runId: runId))
        } catch {
            errors.send((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Cancel an in-flight phone-originated run. Idempotent — calling
    /// twice on the same id is a no-op. The cancellation surfaces
    /// through `DirectE2BClient.run` and the run's final status
    /// becomes `killed`.
    func cancelPhoneRun(runId: String) {
        guard let runTask = phoneRunTasks[runId] else { return }
        runTask.cancel()
        // We don't remove from the map here — the orchestrating task
        // will set the final status to `killed` and remove itself.
    }

    // MARK: - Phone-originated runs (no PC)

    /// Start a run that the phone drives directly against the user's
    /// E2B account. The store keeps the desktop- and phone-originated
    /// runs in separate lists so the view can badge them differently.
    /// The returned `E2bPhoneRun` is also upserted into `phoneRuns`
    /// and updated as events stream in.
    @MainActor
    func startPhoneRun(
        apiKey: String,
        githubToken: String?,
        request: E2bPhoneRunRequest,
    ) {
        // Reject if a previous run with the same id is still going.
        let sameKey = phoneRuns.first(where: { run in
            run.command == request.command
            && run.repoFullName == request.repo.displayName()
            && (run.status == "running" || run.status == "queued")
        })
        if let existing = sameKey {
            errors.send("A run for \(existing.repoFullName) is already in progress.")
            return
        }
        let client = DirectE2BClient(apiKey: apiKey)
        // Seed a queued run so the UI shows it before the network
        // round-trip completes.
        let seed = E2bPhoneRun(
            id: "r_phone_" + UUID().uuidString.prefix(8).lowercased(),
            repoFullName: request.repo.displayName(),
            branch: request.branch,
            command: request.command,
            status: "queued",
            startedAt: Date().timeIntervalSince1970 * 1000,
        )
        phoneRuns.insert(seed, at: 0)
        persistPhoneRuns()

        // The DirectE2BClient.run callback must touch @Published state
        // on the main actor. We hop to the main actor inside the closure.
        let runId = seed.id
        let orchestrator = Task { [weak self] in
            let final = await client.run(request: request) { event in
                Task { @MainActor [weak self] in
                    self?.applyPhoneEvent(runId: runId, event: event)
                }
            }
            await MainActor.run { [weak self] in
                self?.finalizePhoneRun(runId: runId, final: final)
            }
        }
        phoneRunTasks[runId] = orchestrator
    }

    @MainActor
    private func applyPhoneEvent(runId: String, event: E2bPhoneRunEvent) {
        guard let idx = phoneRuns.firstIndex(where: { $0.id == runId }) else { return }
        switch event {
        case let .log(stream, line):
            var updated = phoneRuns[idx]
            // Promote queued → running as soon as we see the first line.
            if updated.status == "queued" { updated.status = "running" }
            // Tag the line with the stream so the view can colour it
            // (mirrors the desktop's `stream: out|err` field).
            let prefixed = stream == "stderr" ? "[stderr] \(line)" : line
            var tail = updated.outputTail
            tail.append(prefixed)
            if tail.count > 5_000 { tail = tail.suffix(5_000) }
            updated.outputTail = tail
            phoneRuns[idx] = updated
            persistPhoneRuns()
        case let .finished(exitCode):
            var updated = phoneRuns[idx]
            updated.status = exitCode == 0 ? "completed" : "failed"
            updated.exitCode = exitCode
            updated.finishedAt = Date().timeIntervalSince1970 * 1000
            phoneRuns[idx] = updated
            persistPhoneRuns()
        case let .failed(message):
            var updated = phoneRuns[idx]
            updated.status = "failed"
            updated.error = message
            updated.finishedAt = Date().timeIntervalSince1970 * 1000
            phoneRuns[idx] = updated
            persistPhoneRuns()
        case let .cancelled(message):
            var updated = phoneRuns[idx]
            updated.status = "killed"
            updated.error = message
            updated.finishedAt = Date().timeIntervalSince1970 * 1000
            phoneRuns[idx] = updated
            persistPhoneRuns()
        }
    }

    @MainActor
    private func finalizePhoneRun(runId: String, final: E2bPhoneRun) {
        // The final run carries the canonical status the client
        // computed (completed / failed / killed). If the row is
        // still around, overwrite it; otherwise push it to the top.
        if let idx = phoneRuns.firstIndex(where: { $0.id == runId }) {
            phoneRuns[idx] = final
        } else {
            phoneRuns.insert(final, at: 0)
        }
        phoneRunTasks.removeValue(forKey: runId)
        persistPhoneRuns()
    }

    /// Disk-persist the current phone-runs list. Coalesced inside
    /// `PhoneRunPersistence` so the rapid log-event updates don't
    /// hammer the filesystem.
    private func persistPhoneRuns() {
        phonePersistence.save(phoneRuns)
    }

    private func existingRunStatus(_ run: E2bPhoneRun) -> String { run.status }

    private func handle(_ msg: ServerMessage) {
        switch msg {
        case let .e2bStarted(_, run):
            upsert(run)
        case let .e2bStatus(_, run):
            upsert(run)
            lastStatusLabel = statusLabel(for: run)
        case let .e2bLog(runId, _, _, line, _):
            appendLog(runId: runId, line: line)
        case let .e2bList(_, serverRuns):
            // Newest first; cap at 100 in the UI to keep the ScrollView
            // happy on long sessions.
            runs = serverRuns.sorted { (a, b) in
                (a.startedAt ?? 0) > (b.startedAt ?? 0)
            }.prefix(100).map { $0 }
        case let .e2bKeyAck(overrideActive):
            hasUserKey = overrideActive
        default:
            break
        }
    }

    private func upsert(_ run: E2bRunPayload) {
        if let idx = runs.firstIndex(where: { $0.id == run.id }) {
            // Trust the server's tail; it has the full picture across
            // reconnects.
            runs[idx] = run
        } else {
            runs.insert(run, at: 0)
        }
    }

    /// Append a single log line to the matching run's tail. Used while
    /// the run is live (the server only sends the full tail on the
    /// terminal `e2b_status` to keep the WS frames small).
    private func appendLog(runId: String, line: String) {
        guard let idx = runs.firstIndex(where: { $0.id == runId }) else { return }
        var updated = runs[idx]
        var tail = updated.outputTail
        tail.append(line)
        // Mirror the server-side cap so the ForEach doesn't blow up.
        if tail.count > 5_000 { tail = tail.suffix(5_000) }
        updated = E2bRunPayload(
            id: updated.id,
            sessionId: updated.sessionId,
            repoFullName: updated.repoFullName,
            branch: updated.branch,
            command: updated.command,
            status: updated.status,
            exitCode: updated.exitCode,
            sandboxId: updated.sandboxId,
            sandboxUrl: updated.sandboxUrl,
            startedAt: updated.startedAt,
            finishedAt: updated.finishedAt,
            outputTail: tail,
            error: updated.error,
        )
        runs[idx] = updated
    }

    private func statusLabel(for run: E2bRunPayload) -> String {
        switch run.status {
        case "completed": return "Last run: completed"
        case "failed": return run.error.map { "Last run failed: \($0)" } ?? "Last run failed"
        case "killed": return "Last run was killed"
        case "running": return "A run is in progress"
        default: return ""
        }
    }
}
