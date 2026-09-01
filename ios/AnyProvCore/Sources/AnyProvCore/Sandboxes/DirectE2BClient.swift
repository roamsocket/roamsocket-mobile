import Foundation

/// A single run of a shell command inside an E2B sandbox, started by the
/// phone. Mirrors the desktop-originated `E2bRunPayload` shape so the
/// Sandboxes view can show both kinds in the same list and mark phone
/// runs with a `phone` badge.
public struct E2bPhoneRun: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    /// "phone" (this struct) — the desktop variants are owned by the
    /// server-side runner. Kept as a free-form string so the view can
    /// switch on the source.
    public let source: String
    public let repoFullName: String
    public let branch: String
    public var command: String
    /// queued | running | completed | failed | killed
    public var status: String
    public var exitCode: Int?
    public var sandboxId: String?
    /// Public URL of the sandbox (when e2b.dev exposes one).
    public var sandboxUrl: String?
    public var startedAt: Double?
    public var finishedAt: Double?
    public var outputTail: [String]
    public var error: String?
    /// Pipeline steps. Always present in new runs (clone, install?,
    /// user). Decoded as empty for old persisted runs that predate
    /// the pipeline — the UI falls back to a single "Output" panel
    /// for those.
    public var steps: [E2bPhoneRunStep]

    public init(
        id: String,
        source: String = "phone",
        repoFullName: String,
        branch: String,
        command: String,
        status: String,
        exitCode: Int? = nil,
        sandboxId: String? = nil,
        sandboxUrl: String? = nil,
        startedAt: Double? = nil,
        finishedAt: Double? = nil,
        outputTail: [String] = [],
        error: String? = nil,
        steps: [E2bPhoneRunStep] = [],
    ) {
        self.id = id
        self.source = source
        self.repoFullName = repoFullName
        self.branch = branch
        self.command = command
        self.status = status
        self.exitCode = exitCode
        self.sandboxId = sandboxId
        self.sandboxUrl = sandboxUrl
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outputTail = outputTail
        self.error = error
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case id, source, repoFullName, branch, command, status, exitCode
        case sandboxId, sandboxUrl, startedAt, finishedAt, outputTail, error, steps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "phone"
        repoFullName = try c.decode(String.self, forKey: .repoFullName)
        branch = try c.decode(String.self, forKey: .branch)
        command = try c.decode(String.self, forKey: .command)
        status = try c.decode(String.self, forKey: .status)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        sandboxId = try c.decodeIfPresent(String.self, forKey: .sandboxId)
        sandboxUrl = try c.decodeIfPresent(String.self, forKey: .sandboxUrl)
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Double.self, forKey: .finishedAt)
        outputTail = try c.decodeIfPresent([String].self, forKey: .outputTail) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
        // Backward compat: pre-pipeline runs are missing `steps`.
        steps = try c.decodeIfPresent([E2bPhoneRunStep].self, forKey: .steps) ?? []
    }
}

/// One step inside an `E2bPhoneRun` pipeline. Steps are reported by
/// the Python shim via `STEP:<id>:start` / `STEP:<id>:done` /
/// `STEP:<id>:failed:<code>` / `STEP:<id>:skipped` markers.
public struct E2bPhoneRunStep: Codable, Hashable, Sendable, Identifiable {
    /// Stable id the shim uses: `clone`, `install`, `user`.
    public let id: String
    /// Human-friendly name for the step pill: "Clone", "Install", "Test".
    public let name: String
    /// pending | running | completed | failed | skipped
    public var status: String
    public var exitCode: Int?
    public var startedAt: Double?
    public var finishedAt: Double?
    public var outputTail: [String]
    /// Optional error message set by the phone when the step failed
    /// (e.g. "git clone failed (exit 128)").
    public var error: String?

    public init(
        id: String,
        name: String,
        status: String = "pending",
        exitCode: Int? = nil,
        startedAt: Double? = nil,
        finishedAt: Double? = nil,
        outputTail: [String] = [],
        error: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outputTail = outputTail
        self.error = error
    }
}

/// Where the run's source repository lives.
public enum E2bPhoneRepoSource: String, Sendable, Hashable {
    case github
    case url
}

/// A request the phone sends to spin up a new E2B sandbox. Used by the
/// "Start a run" sheet in `SandboxesView`.
public struct E2bPhoneRunRequest: Sendable, Hashable {
    public var repo: E2bPhoneRepoSelection
    public var branch: String
    public var command: String
    /// Optional install step that runs after `clone` and before the
    /// user command. `nil` (or empty) means the install step is
    /// skipped — the shim emits `STEP:install:skipped` so the UI
    /// can render the pill in a "skipped" state.
    public var installCommand: String?
    /// Optional override; falls back to the user's GitHub token for
    /// private repos when `repo == .github` and the token is set.
    public var githubToken: String?
    /// What preset the user picked. Free-form string so the view can
    /// switch on it (e.g. "test", "build", "lint", "install",
    /// "custom"). The shim does not consume this — it only drives
    /// the step pill label.
    public var preset: String?

    public init(
        repo: E2bPhoneRepoSelection,
        branch: String,
        command: String,
        installCommand: String? = nil,
        githubToken: String? = nil,
        preset: String? = nil,
    ) {
        self.repo = repo
        self.branch = branch
        self.command = command
        self.installCommand = installCommand
        self.githubToken = githubToken
        self.preset = preset
    }
}

/// Either a GitHub repo (full name like "owner/name") or a raw URL.
public enum E2bPhoneRepoSelection: Hashable, Sendable {
    case github(fullName: String)
    case url(String)

    public func displayName() -> String {
        switch self {
        case let .github(name): return name
        case let .url(u): return u
        }
    }
}

/// Events streamed from a live E2B sandbox run.
public enum E2bPhoneRunEvent: Sendable, Hashable {
    /// A new line of output. `stream` is "stdout" or "stderr".
    /// `stepId` is the id of the step currently active (e.g. "clone",
    /// "install", "user") so the view-model can attribute the line
    /// to the right step pill. `nil` for lines emitted before any
    /// step has started (e.g. "Creating sandbox…").
    case log(stream: String, line: String, stepId: String?)
    /// A pipeline step just started.
    case stepStarted(stepId: String)
    /// A pipeline step finished cleanly.
    case stepDone(stepId: String)
    /// A pipeline step failed.
    case stepFailed(stepId: String, exitCode: Int)
    /// A pipeline step was skipped (only happens for the `install`
    /// step when no install command was supplied).
    case stepSkipped(stepId: String)
    /// Run finished.
    case finished(exitCode: Int?)
    /// Run failed to set up or stream.
    case failed(message: String)
    /// The caller's `Task` was cancelled. Distinct from `.failed` so
    /// the UI can mark the row `killed` without showing an error.
    case cancelled(message: String)
}

public enum DirectE2BError: Error, LocalizedError {
    case noApiKey
    case http(status: Int, body: String)
    case decoding(String)
    case stream(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .noApiKey: return "Add your e2b.dev API key in Settings first."
        case let .http(status, body):
            let snippet = body.isEmpty ? "" : " — \(body.prefix(160))"
            return "E2B HTTP \(status)\(snippet)"
        case let .decoding(msg): return "Failed to decode E2B response: \(msg)"
        case let .stream(msg): return "E2B stream: \(msg)"
        case let .transport(msg): return "E2B transport: \(msg)"
        }
    }
}

/// Out-of-session client for the E2B.dev HTTP API. Used when the user
/// wants to spin up a sandbox from the phone without a paired desktop.
///
/// Implementation note: e2b.dev exposes a full envd Connect-RPC API for
/// the general `base` template. Implementing Connect-RPC + protobuf from
/// scratch in Swift is a large lift, so this MVP routes shell commands
/// through the simpler `code-interpreter` template's JSON streaming
/// endpoint. The shell command runs inside a Python `subprocess` that
/// streams each line back through the code-interpreter NDJSON response.
public final class DirectE2BClient: @unchecked Sendable {
    /// e2b's API host. Public — the desktop runner uses the same one.
    public static let apiHost = "api.e2b.dev"
    public static let codeInterpreterPort = 49999
    public static let codeInterpreterTemplate = "code-interpreter-beta"

    private let http: HTTPClient
    private let apiKey: String
    private let baseURL: URL

    public init(
        apiKey: String,
        http: HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = URL(string: "https://api.e2b.dev")!,
    ) {
        self.apiKey = apiKey
        self.http = http
        self.baseURL = baseURL
    }

    // MARK: - Sandbox lifecycle

    /// Create a fresh sandbox. Returns the e2b sandbox id and the
    /// "X-Access-Token" the sandbox returned; the token is needed to
    /// authenticate follow-up calls into the sandbox itself.
    public func createSandbox(template: String = DirectE2BClient.codeInterpreterTemplate, timeoutMs: Int = 600_000) async throws -> E2bSandboxInfo {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DirectE2BError.noApiKey }

        var req = URLRequest(url: baseURL.appendingPathComponent("sandboxes"))
        req.httpMethod = "POST"
        req.setValue(trimmed, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "templateID": template,
            "timeout": timeoutMs,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.data(for: req)
        } catch {
            throw DirectE2BError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DirectE2BError.http(status: response.statusCode, body: body)
        }
        struct Raw: Decodable {
            let sandboxID: String
            let clientID: String?
            let envdVersion: String?
        }
        do {
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            // The access token comes back in `X-Access-Token` if the
            // sandbox is secured; it's optional in the response body.
            let access = response.value(forHTTPHeaderField: "X-Access-Token")
            return E2bSandboxInfo(
                sandboxId: raw.sandboxID,
                accessToken: access,
                domain: "e2b.dev",
                template: template,
            )
        } catch {
            throw DirectE2BError.decoding(String(describing: error))
        }
    }

    /// Kill a sandbox by id. Best-effort: errors are swallowed because
    /// the sandbox may have already timed out.
    public func killSandbox(sandboxId: String) async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("sandboxes/\(sandboxId)"))
        req.httpMethod = "DELETE"
        req.setValue(trimmed, forHTTPHeaderField: "X-API-Key")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        _ = try? await http.data(for: req)
    }

    /// Cheap key check: `GET /sandboxes?limit=1`. Used by the Settings
    /// card after the user pastes a key to confirm it actually works
    /// (and that the account has a sandbox quota). Returns the raw
    /// HTTP status so the UI can show "verified" vs "rejected".
    ///
    /// - Throws: `DirectE2BError.noApiKey` for an empty key, or
    ///   `DirectE2BError.http` for any non-2xx response.
    @discardableResult
    public func verifyKey() async throws -> Int {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DirectE2BError.noApiKey }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("sandboxes"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "limit", value: "1")]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue(trimmed, forHTTPHeaderField: "X-API-Key")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.data(for: req)
        } catch {
            throw DirectE2BError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DirectE2BError.http(status: response.statusCode, body: body)
        }
        return response.statusCode
    }

    // MARK: - Run a shell command via the code-interpreter shim

    /// Build the Python shim that runs the phone-originated pipeline:
    /// `clone → install? → user command`. Each step is bracketed by
    /// `STEP:<id>:start` / `STEP:<id>:done` / `STEP:<id>:failed:N` /
    /// `STEP:<id>:skipped` markers so the phone-side state machine
    /// can drive a multi-pill UI. `installCommand` is optional; when
    /// `nil` or empty the install step is emitted as `skipped` and
    /// the script falls straight through to the user command.
    ///
    /// Exposed publicly so the Sandboxes UI can preview the script
    /// and unit tests can lock the output against regressions.
    public static func makeShimScript(
        repo: E2bPhoneRepoSelection,
        branch: String,
        command: String,
        githubToken: String?,
        installCommand: String? = nil,
    ) -> String {
        // `git clone` URL. For private GitHub repos we inject the token
        // as a basic-auth user (`oauth2:<token>@github.com/...`).
        let cloneURL: String
        switch repo {
        case let .github(fullName):
            if let token = githubToken, !token.isEmpty {
                cloneURL = "https://oauth2:\(token)@github.com/\(fullName).git"
            } else {
                cloneURL = "https://github.com/\(fullName).git"
            }
        case let .url(u):
            cloneURL = u
        }
        // shlex.quote() prevents command injection from the user's
        // command string. The install command is optional; when
        // empty we still emit a Python `None` so the shim can branch
        // to "STEP:install:skipped" without crashing.
        let quotedBranch = PythonQuote.escape(branch)
        let quotedURL = PythonQuote.escape(cloneURL)
        let quotedCommand = PythonQuote.escape(command)
        let installLiteral: String = {
            let trimmed = (installCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "None" }
            return PythonQuote.escape(trimmed)
        }()
        // The shim writes to /code (code-interpreter's default cwd).
        // The streaming contract:
        //   STDOUT:<line>\n
        //   STDERR:<line>\n
        //   STEP:<id>:start | done | failed:<n> | skipped\n
        //   EXIT:<code>\n
        // The caller (this client) splits each NDJSON record on the
        // first ':' to recover the stream type and the line.
        return """
        import subprocess, sys, shlex

        def emit(stream, line):
            sys.stdout.write(f"{stream.upper()}:{line}")
            if not line.endswith("\\n"):
                sys.stdout.write("\\n")
            sys.stdout.flush()

        def step_start(name):
            sys.stdout.write(f"STEP:{name}:start\\n"); sys.stdout.flush()

        def step_done(name):
            sys.stdout.write(f"STEP:{name}:done\\n"); sys.stdout.flush()

        def step_failed(name, code):
            sys.stdout.write(f"STEP:{name}:failed:{code}\\n"); sys.stdout.flush()

        def step_skipped(name):
            sys.stdout.write(f"STEP:{name}:skipped\\n"); sys.stdout.flush()

        def run_streamed(cmd, cwd):
            try:
                proc = subprocess.Popen(
                    cmd, shell=True, cwd=cwd,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    text=True, bufsize=1,
                )
            except Exception as exc:
                emit("stderr", f"launch failed: {exc}")
                return -1
            import threading
            def pump(stream, label):
                for line in stream:
                    emit(label, line.rstrip("\\n"))
                stream.close()
            t_out = threading.Thread(target=pump, args=(proc.stdout, "stdout"), daemon=True)
            t_err = threading.Thread(target=pump, args=(proc.stderr, "stderr"), daemon=True)
            t_out.start(); t_err.start()
            proc.wait()
            t_out.join(timeout=2); t_err.join(timeout=2)
            return proc.returncode

        # 1. Clone the repo into /code (with branch checkout).
        clone_url = \(quotedURL)
        branch = \(quotedBranch)
        user_cmd = \(quotedCommand)
        install_cmd = \(installLiteral)

        step_start("clone")
        proc = subprocess.run(
            ["git", "clone", "--depth", "1", clone_url, "/code"],
            capture_output=True, text=True,
        )
        for line in proc.stdout.splitlines():
            emit("stdout", line)
        for line in proc.stderr.splitlines():
            emit("stderr", line)
        if proc.returncode != 0:
            step_failed("clone", proc.returncode)
            emit("exit", "1")
            sys.exit(0)
        # Always re-fetch the target branch tip, even after a fresh
        # clone. The depth-1 clone above only got the default
        # branch's HEAD — if the user just `git push`-ed a new
        # commit to a feature branch, the clone is stale. `git fetch
        # origin <branch>` pulls the tip of the target branch so the
        # build runs against the freshly pushed commit, not whatever
        # happened to be in the default branch.
        try:
            fetch = subprocess.run(
                ["git", "fetch", "--depth", "1", "origin", branch],
                cwd="/code", capture_output=True, text=True,
            )
            for line in fetch.stdout.splitlines():
                emit("stdout", line)
            for line in fetch.stderr.splitlines():
                emit("stderr", line)
            if fetch.returncode != 0:
                emit("stderr", f"git fetch origin {branch} failed (exit {fetch.returncode})")
                step_failed("clone", fetch.returncode)
                emit("exit", "1")
                sys.exit(0)
            checkout = subprocess.run(
                ["git", "checkout", branch],
                cwd="/code", capture_output=True, text=True,
            )
            for line in checkout.stdout.splitlines():
                emit("stdout", line)
            for line in checkout.stderr.splitlines():
                emit("stderr", line)
            if checkout.returncode != 0:
                emit("stderr", f"git checkout {branch} failed (exit {checkout.returncode})")
                step_failed("clone", checkout.returncode)
                emit("exit", "1")
                sys.exit(0)
        except Exception as exc:
            emit("stderr", f"checkout failed: {exc}")
            step_failed("clone", 1)
            emit("exit", "1")
            sys.exit(0)
        # Surface the resolved HEAD so the user can see exactly which
        # commit was built. Helps catch the "wrong branch" / "stale
        # clone" case without having to guess from the build output.
        head = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd="/code", capture_output=True, text=True,
        )
        if head.returncode == 0:
            emit("stdout", f"HEAD: {head.stdout.strip()} on {branch}")
        step_done("clone")

        # 2. Install dependencies (skipped if the request didn't supply one).
        if install_cmd is None:
            step_skipped("install")
        else:
            step_start("install")
            install_code = run_streamed(install_cmd, "/code")
            if install_code != 0:
                step_failed("install", install_code)
                emit("exit", str(install_code))
                sys.exit(0)
            step_done("install")

        # 3. User command.
        step_start("user")
        user_code = run_streamed(user_cmd, "/code")
        if user_code != 0:
            step_failed("user", user_code)
        else:
            step_done("user")
        emit("exit", str(user_code))
        """
    }

    /// Run `request` end-to-end against the user's E2B account. Yields
    /// events as the run progresses. The run lifecycle is owned by the
    /// caller — `task` returns when the run finishes (or fails).
    ///
    /// - Parameters:
    ///   - request: the repo + branch + command to run.
    ///   - onEvent: invoked for each log line + the final status.
    ///     Implementations typically update the view-model's
    ///     `outputTail` on every log and the `status` on the finish /
    ///     failure events.
    /// - Returns: the final `E2bPhoneRun` (with the terminal status,
    ///   exit code, sandbox id, and output tail).
    @discardableResult
    public func run(
        request: E2bPhoneRunRequest,
        onEvent: @escaping @Sendable (E2bPhoneRunEvent) -> Void,
    ) async -> E2bPhoneRun {
        // Track the currently-active pipeline step so `.log` events
        // can be attributed to the right pill. `nil` before any
        // step starts.
        var currentStepId: String? = nil
        var run = E2bPhoneRun(
            id: "r_phone_" + UUID().uuidString.prefix(8).lowercased(),
            repoFullName: request.repo.displayName(),
            branch: request.branch,
            command: request.command,
            status: "queued",
            startedAt: Date().timeIntervalSince1970 * 1000,
        )
        onEvent(.log(stream: "stdout", line: "Creating sandbox…", stepId: nil))

        let sandbox: E2bSandboxInfo
        do {
            sandbox = try await createSandbox()
        } catch {
            var failed = run
            failed.status = "failed"
            failed.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            failed.finishedAt = Date().timeIntervalSince1970 * 1000
            onEvent(.failed(message: failed.error ?? "Sandbox creation failed."))
            return failed
        }
        run.sandboxId = sandbox.sandboxId
        run.sandboxUrl = "https://\(sandbox.sandboxId).\(sandbox.domain)"
        run.status = "running"
        onEvent(.log(stream: "stdout", line: "Sandbox ready: \(sandbox.sandboxId)", stepId: nil))

        // 2. POST the Python shim to the code-interpreter execute endpoint
        //    and stream the NDJSON response.
        let script = DirectE2BClient.makeShimScript(
            repo: request.repo,
            branch: request.branch,
            command: request.command,
            githubToken: request.githubToken,
            installCommand: request.installCommand,
        )
        let executeURL = URL(string: "https://\(DirectE2BClient.codeInterpreterPort)-\(sandbox.sandboxId).\(sandbox.domain)/execute")!
        var req = URLRequest(url: executeURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        if let token = sandbox.accessToken {
            req.setValue(token, forHTTPHeaderField: "X-Access-Token")
        }
        let body: [String: Any] = ["code": script]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let session = URLSession.shared
        var exitCode: Int?
        var streamError: String?
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw DirectE2BError.stream("execute HTTP \(code)")
            }
            for try await line in bytes.lines {
                switch E2bPhoneStreamEvent.parse(line: line) {
                case let .stdout(value):
                    onEvent(.log(stream: "stdout", line: value, stepId: currentStepId))
                case let .stderr(value):
                    onEvent(.log(stream: "stderr", line: value, stepId: currentStepId))
                case let .stepStart(id):
                    currentStepId = id
                    onEvent(.stepStarted(stepId: id))
                case let .stepDone(id):
                    onEvent(.stepDone(stepId: id))
                    if currentStepId == id { currentStepId = nil }
                case let .stepFailed(id, code):
                    onEvent(.stepFailed(stepId: id, exitCode: code))
                    if currentStepId == id { currentStepId = nil }
                case let .stepSkipped(id):
                    onEvent(.stepSkipped(stepId: id))
                    if currentStepId == id { currentStepId = nil }
                case let .exit(code):
                    exitCode = code
                case let .cloneFailed(code):
                    streamError = "git clone failed (exit \(code))"
                case .checkoutFailed:
                    streamError = "git checkout failed"
                case .launchFailed:
                    streamError = "command launch failed"
                case let .passthrough(raw):
                    onEvent(.log(stream: "stdout", line: raw, stepId: currentStepId))
                }
            }
        } catch {
            streamError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }

        // 3. Best-effort: kill the sandbox so we don't leave it running.
        await killSandbox(sandboxId: sandbox.sandboxId)

        // Cancellation is cooperative. When the caller's `Task` is
        // cancelled, the streaming loop's `try await` throws and we
        // land here. Surface a distinct `killed` status so the UI can
        // grey the row out without showing an error message.
        let wasCancelled = Task.isCancelled
        if wasCancelled {
            run.status = "killed"
            run.error = streamError ?? "Run cancelled."
        } else if let streamError {
            run.status = "failed"
            run.error = streamError
        } else if let exitCode {
            run.status = exitCode == 0 ? "completed" : "failed"
            run.exitCode = exitCode
        } else {
            run.status = "failed"
            run.error = "Sandbox stream ended without an exit code."
        }
        run.finishedAt = Date().timeIntervalSince1970 * 1000
        if wasCancelled {
            onEvent(.cancelled(message: run.error ?? "Run cancelled."))
        } else {
            onEvent(exitCode == 0 ? .finished(exitCode: exitCode) : .failed(message: run.error ?? "Failed."))
        }
        return run
    }
}

/// Lightweight model for the metadata returned by `POST /sandboxes`.
public struct E2bSandboxInfo: Sendable, Hashable {
    public let sandboxId: String
    public let accessToken: String?
    public let domain: String
    public let template: String

    public init(sandboxId: String, accessToken: String?, domain: String, template: String) {
        self.sandboxId = sandboxId
        self.accessToken = accessToken
        self.domain = domain
        self.template = template
    }
}

/// Python shlex.quote replacement. Matches CPython's behavior: wraps
/// the string in single quotes and escapes any embedded single quotes
/// by closing + escaping + reopening the string.
///
/// Exposed publicly so the shim's escaping can be unit-tested
/// independently of `makeShimScript`.
public enum PythonQuote {
    public static func escape(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_-./:=@%+,"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}

/// One parsed line from the code-interpreter's NDJSON response.
/// The shim prefixes each line with `STDOUT:` / `STDERR:` /
/// `STEP:<id>:...` / `EXIT:` and the client demuxes that into
/// structured events so the view-model and the unit tests can stay
/// in sync.
public enum E2bPhoneStreamEvent: Sendable, Hashable {
    case stdout(String)
    case stderr(String)
    /// Process exit code. `nil` exit means the stream ended before
    /// the shim sent an EXIT line — usually a sandbox crash.
    case exit(Int)
    /// The shim caught a fatal error before launching the user command.
    case cloneFailed(exitCode: Int)
    case checkoutFailed
    case launchFailed
    /// Step lifecycle. `clone`, `install`, `user` are the step ids
    /// the current shim emits; the parser is forward-compatible with
    /// new step ids.
    case stepStart(String)
    case stepDone(String)
    case stepFailed(String, exitCode: Int)
    case stepSkipped(String)
    /// A line that didn't match the prefix scheme. The view shows it
    /// as stdout so it isn't lost (forward-compat for new shim output).
    case passthrough(String)

    /// Pure parser. Exposed for unit tests.
    public static func parse(line: String) -> E2bPhoneStreamEvent {
        guard let sep = line.firstIndex(of: ":") else {
            return .passthrough(line)
        }
        let kind = String(line[..<sep])
        let value = String(line[line.index(after: sep)...])
        switch kind {
        case "STDOUT": return .stdout(value)
        case "STDERR": return .stderr(value)
        case "STEP":
            // Re-split `value` on `:`. Up to three parts:
            //   STEP:<id>:start
            //   STEP:<id>:done
            //   STEP:<id>:skipped
            //   STEP:<id>:failed:<code>
            let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return .passthrough(line) }
            let stepId = String(parts[0])
            let op = String(parts[1])
            switch op {
            case "start": return .stepStart(stepId)
            case "done": return .stepDone(stepId)
            case "skipped": return .stepSkipped(stepId)
            case "failed":
                let code = parts.count >= 3 ? (Int(parts[2]) ?? -1) : -1
                return .stepFailed(stepId, exitCode: code)
            default:
                return .passthrough(line)
            }
        case "EXIT":
            if value.hasPrefix("clone-failed:") {
                let code = Int(value.dropFirst("clone-failed:".count)) ?? -1
                return .cloneFailed(exitCode: code)
            }
            if value == "checkout-failed" { return .checkoutFailed }
            if value == "launch-failed" { return .launchFailed }
            return .exit(Int(value) ?? -1)
        default:
            return .passthrough(line)
        }
    }
}
