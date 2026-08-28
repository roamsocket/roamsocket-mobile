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
    /// Optional override; falls back to the user's GitHub token for
    /// private repos when `repo == .github` and the token is set.
    public var githubToken: String?

    public init(
        repo: E2bPhoneRepoSelection,
        branch: String,
        command: String,
        githubToken: String? = nil,
    ) {
        self.repo = repo
        self.branch = branch
        self.command = command
        self.githubToken = githubToken
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
    case log(stream: String, line: String)
    /// Run finished.
    case finished(exitCode: Int?)
    /// Run failed to set up or stream.
    case failed(message: String)
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

    // MARK: - Run a shell command via the code-interpreter shim

    /// Build the Python shim that clones `repo`, checks out `branch`,
    /// then runs `command`. Output is streamed back via the
    /// code-interpreter's NDJSON response.
    private static func buildShimScript(repo: E2bPhoneRepoSelection, branch: String, command: String, githubToken: String?) -> String {
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
        // command string.
        let quotedBranch = PythonQuote.escape(branch)
        let quotedURL = PythonQuote.escape(cloneURL)
        let quotedCommand = PythonQuote.escape(command)
        // The shim writes to /code (code-interpreter's default cwd).
        // The streaming contract:
        //   STDOUT:<line>\n
        //   STDERR:<line>\n
        //   EXIT:<code>\n
        // The caller (this client) splits each NDJSON record on the
        // first ':' to recover the stream type and the line.
        return """
        import subprocess, sys, os, shlex

        def emit(stream, line):
            sys.stdout.write(f"{stream.upper()}:{line}")
            if not line.endswith("\\n"):
                sys.stdout.write("\\n")
            sys.stdout.flush()

        # 1. Clone the repo into /code.
        clone_url = \(quotedURL)
        branch = \(quotedBranch)
        proc = subprocess.run(
            ["git", "clone", "--depth", "1", clone_url, "/code"],
            capture_output=True, text=True,
        )
        for line in proc.stdout.splitlines():
            emit("stdout", line)
        for line in proc.stderr.splitlines():
            emit("stderr", line)
        if proc.returncode != 0:
            emit("exit", f"clone-failed:{proc.returncode}")
            sys.exit(0)

        # 2. Switch to the requested branch (depth-1 only has one
        #    branch — fetch the other one if needed).
        try:
            proc = subprocess.run(
                ["git", "fetch", "--depth", "1", "origin", branch],
                cwd="/code", capture_output=True, text=True,
            )
            for line in proc.stderr.splitlines():
                emit("stderr", line)
            subprocess.run(
                ["git", "checkout", branch],
                cwd="/code", check=True, capture_output=True, text=True,
            )
        except Exception as exc:
            emit("stderr", f"checkout failed: {exc}")
            emit("exit", "checkout-failed")
            sys.exit(0)

        # 3. Run the user command with live streaming.
        try:
            proc = subprocess.Popen(
                \(quotedCommand),
                shell=True,
                cwd="/code",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
        except Exception as exc:
            emit("stderr", f"launch failed: {exc}")
            emit("exit", "launch-failed")
            sys.exit(0)

        import threading
        def pump(stream, label):
            for line in stream:
                emit(label, line.rstrip("\\n"))
            stream.close()
        t_out = threading.Thread(target=pump, args=(proc.stdout, "stdout"), daemon=True)
        t_err = threading.Thread(target=pump, args=(proc.stderr, "stderr"), daemon=True)
        t_out.start()
        t_err.start()
        proc.wait()
        t_out.join(timeout=2)
        t_err.join(timeout=2)
        emit("exit", str(proc.returncode))
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
        var run = E2bPhoneRun(
            id: "r_phone_" + UUID().uuidString.prefix(8).lowercased(),
            repoFullName: request.repo.displayName(),
            branch: request.branch,
            command: request.command,
            status: "queued",
            startedAt: Date().timeIntervalSince1970 * 1000,
        )
        onEvent(.log(stream: "stdout", line: "Creating sandbox…"))

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
        onEvent(.log(stream: "stdout", line: "Sandbox ready: \(sandbox.sandboxId)"))

        // 2. POST the Python shim to the code-interpreter execute endpoint
        //    and stream the NDJSON response.
        let script = DirectE2BClient.buildShimScript(
            repo: request.repo,
            branch: request.branch,
            command: request.command,
            githubToken: request.githubToken,
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
                // Each line is `STREAM:value` (or `EXIT:code`).
                if let sep = line.firstIndex(of: ":") {
                    let kind = String(line[..<sep])
                    let value = String(line[line.index(after: sep)...])
                    switch kind {
                    case "STDOUT":
                        onEvent(.log(stream: "stdout", line: value))
                    case "STDERR":
                        onEvent(.log(stream: "stderr", line: value))
                    case "EXIT":
                        if value.hasPrefix("clone-failed:") {
                            streamError = "git clone failed (exit \(value.dropFirst("clone-failed:".count)))"
                        } else if value == "checkout-failed" {
                            streamError = "git checkout failed"
                        } else if value == "launch-failed" {
                            streamError = "command launch failed"
                        } else {
                            exitCode = Int(value)
                        }
                    default:
                        onEvent(.log(stream: "stdout", line: line))
                    }
                } else {
                    onEvent(.log(stream: "stdout", line: line))
                }
            }
        } catch {
            streamError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }

        // 3. Best-effort: kill the sandbox so we don't leave it running.
        await killSandbox(sandboxId: sandbox.sandboxId)

        if let streamError {
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
        onEvent(exitCode == 0 ? .finished(exitCode: exitCode) : .failed(message: run.error ?? "Failed."))
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
private enum PythonQuote {
    static func escape(_ value: String) -> String {
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
