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

    /// Errors surfaced from the connection itself (handshake failure,
    /// send failure). One-shot — the view shows them in an alert.
    let errors = PassthroughSubject<String?, Never>()

    private let client = ServerClient()
    private var task: Task<Void, Never>?

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
        do {
            try await client.send(.e2bAbort(runId: runId))
        } catch {
            errors.send((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

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
