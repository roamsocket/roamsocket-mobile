import Foundation
import Combine
import AnyProvCore

/// Drives the Sandboxes sheet. Phone-only — the desktop is no
/// longer in the loop, so this store owns the full lifecycle of a
/// run: creating the sandbox via `DirectE2BClient`, streaming events
/// into the multi-step state machine, and persisting the result to
/// disk so the history survives launches.
///
/// The store is `@MainActor` because the `phoneRuns` array backs the
/// view directly; long-running work (creating the sandbox, streaming
/// output) is hopped off the main actor via `Task`.
@MainActor
final class SandboxesStore: ObservableObject {
    /// Phone-originated runs, newest first. Persisted to
    /// `Application Support/phoneRuns.v1.json` so the history
    /// survives launches (see `PhoneRunPersistence`).
    @Published private(set) var phoneRuns: [E2bPhoneRun] = []

    /// One-shot errors surfaced by the start sheet (key missing,
    /// sandbox creation failure, etc.). The view shows them in an
    /// alert and clears the published value.
    let errors = PassthroughSubject<String?, Never>()

    /// In-flight phone-originated runs. Used so the view's "Stop"
    /// button can cancel the orchestrating `Task`.
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

    /// Start a phone-originated run. Creates the sandbox via
    /// `DirectE2BClient`, streams events back into the multi-step
    /// state machine, and persists the final row.
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
        // Seed the run with the planned pipeline steps so the UI can
        // render the step pills in their "pending" state from the
        // first frame, before any events arrive.
        let steps = Self.makeInitialSteps(for: request)
        let runId = "r_phone_" + UUID().uuidString.prefix(8).lowercased()
        let seed = E2bPhoneRun(
            id: runId,
            repoFullName: request.repo.displayName(),
            branch: request.branch,
            command: request.command,
            status: "queued",
            startedAt: Date().timeIntervalSince1970 * 1000,
            steps: steps,
        )
        phoneRuns.insert(seed, at: 0)
        persistPhoneRuns()

        // The DirectE2BClient.run callback touches @Published state
        // on the main actor — we hop to the main actor inside the
        // closure. The Task reference is stored so the view's Stop
        // button can cancel a long-running install or test step.
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

    /// Cancel an in-flight phone-originated run. Idempotent. The
    /// cancellation flows through `DirectE2BClient.run` and lands
    /// the row as `killed`.
    func cancelPhoneRun(runId: String) {
        guard let runTask = phoneRunTasks[runId] else { return }
        runTask.cancel()
        // Don't remove from the map here — the orchestrating task
        // will set the final status to `killed` and remove itself.
    }

    // MARK: - SandboxesStoreView housekeeping

    /// Tear down any in-flight phone runs and flush the debounced
    /// persistence write. Call from `onDisappear` so the very last
    /// mutation isn't lost on background.
    func stop() {
        for (_, runTask) in phoneRunTasks {
            runTask.cancel()
        }
        phoneRunTasks.removeAll()
        phonePersistence.flushNow()
    }

    // MARK: - Step pipeline

    /// Build the initial step list for a new run. The "user" step
    /// is always present; the "install" step is present only when
    /// the request supplies an `installCommand`.
    private static func makeInitialSteps(for request: E2bPhoneRunRequest) -> [E2bPhoneRunStep] {
        var steps: [E2bPhoneRunStep] = [
            E2bPhoneRunStep(id: "clone", name: "Clone"),
        ]
        if let install = request.installCommand, !install.isEmpty {
            steps.append(E2bPhoneRunStep(id: "install", name: "Install"))
        }
        let userName: String = {
            switch request.preset {
            case "test": return "Test"
            case "build": return "Build"
            case "lint": return "Lint"
            case "install": return "Install"
            default: return "Run"
            }
        }()
        steps.append(E2bPhoneRunStep(id: "user", name: userName))
        return steps
    }

    @MainActor
    private func applyPhoneEvent(runId: String, event: E2bPhoneRunEvent) {
        guard let idx = phoneRuns.firstIndex(where: { $0.id == runId }) else { return }
        switch event {
        case let .log(stream, line, stepId):
            var updated = phoneRuns[idx]
            // Promote queued → running as soon as we see the first line.
            if updated.status == "queued" { updated.status = "running" }
            // Tag stderr so the view can colour it. Mirrors the
            // desktop's `stream: out|err` convention.
            let prefixed = stream == "stderr" ? "[stderr] \(line)" : line
            // Append to the per-step output if we have a step id,
            // otherwise fall back to the global outputTail.
            if let stepId, let stepIdx = updated.steps.firstIndex(where: { $0.id == stepId }) {
                var step = updated.steps[stepIdx]
                var tail = step.outputTail
                tail.append(prefixed)
                if tail.count > 5_000 { tail = tail.suffix(5_000) }
                step.outputTail = tail
                updated.steps[stepIdx] = step
            } else {
                var tail = updated.outputTail
                tail.append(prefixed)
                if tail.count > 5_000 { tail = tail.suffix(5_000) }
                updated.outputTail = tail
            }
            phoneRuns[idx] = updated
            persistPhoneRuns()
        case let .stepStarted(stepId):
            var updated = phoneRuns[idx]
            if let stepIdx = updated.steps.firstIndex(where: { $0.id == stepId }) {
                var step = updated.steps[stepIdx]
                step.status = "running"
                step.startedAt = Date().timeIntervalSince1970 * 1000
                updated.steps[stepIdx] = step
            }
            phoneRuns[idx] = updated
            persistPhoneRuns()
        case let .stepDone(stepId):
            var updated = phoneRuns[idx]
            if let stepIdx = updated.steps.firstIndex(where: { $0.id == stepId }) {
                var step = updated.steps[stepIdx]
                step.status = "completed"
                step.finishedAt = Date().timeIntervalSince1970 * 1000
                updated.steps[stepIdx] = step
            }
            phoneRuns[idx] = updated
            persistPhoneRuns()
        case let .stepFailed(stepId, exitCode):
            var updated = phoneRuns[idx]
            if let stepIdx = updated.steps.firstIndex(where: { $0.id == stepId }) {
                var step = updated.steps[stepIdx]
                step.status = "failed"
                step.exitCode = exitCode
                step.finishedAt = Date().timeIntervalSince1970 * 1000
                updated.steps[stepIdx] = step
            }
            phoneRuns[idx] = updated
            persistPhoneRuns()
        case let .stepSkipped(stepId):
            var updated = phoneRuns[idx]
            if let stepIdx = updated.steps.firstIndex(where: { $0.id == stepId }) {
                var step = updated.steps[stepIdx]
                step.status = "skipped"
                step.finishedAt = Date().timeIntervalSince1970 * 1000
                updated.steps[stepIdx] = step
            }
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
}
