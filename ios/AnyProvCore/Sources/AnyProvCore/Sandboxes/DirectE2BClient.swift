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
            return "E2B HTTP \(status): \(Self.friendlyMessage(status: status, body: body))"
        case let .decoding(msg): return "Failed to decode E2B response: \(msg)"
        case let .stream(msg): return "E2B stream: \(msg)"
        case let .transport(msg): return "E2B transport: \(msg)"
        }
    }

    /// Turn an e2b.dev error response body into a short,
    /// human-readable message.
    ///
    /// e2b returns JSON shaped like
    /// `{"code":…,"message":"…","error_code":"…"}` — when it
    /// parses we surface the `message` verbatim. Anything else (proxy
    /// errors, HTML, empty bodies) falls back to the first line of the
    /// raw body, truncated, so callers never dump the full JSON blob
    /// into the UI.
    public static func friendlyMessage(status: Int, body: String) -> String {
        struct Payload: Decodable {
            let message: String?
            let errorCode: String?
            enum CodingKeys: String, CodingKey {
                case message
                case errorCode = "error_code"
            }
        }
        if let data = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           let message = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? ""
        if !firstLine.isEmpty {
            return firstLine.count > 160 ? String(firstLine.prefix(160)) + "…" : firstLine
        }
        return "HTTP \(status) with no message"
    }
}

// MARK: - Persistent sandbox primitives

extension DirectE2BClient {
    /// Execute an arbitrary Python script on a persistent sandbox
    /// and return its stdout. Used by the chat-driven E2B agent
    /// (file ops, git, PR creation) where the sandbox must stay
    /// alive across multiple operations.
    ///
    /// The `code` runs inside the code-interpreter template's
    /// Python REPL, with full filesystem + subprocess access.
    /// On a non-zero exit (uncaught exception) the error message
    /// is thrown as a `.stream` error. Stdout is returned
    /// verbatim — callers are expected to format their scripts
    /// to print JSON or another parseable format.
    public func exec(
        sandboxId: String,
        accessToken: String?,
        code: String,
        timeoutMs: Int = 60_000,
    ) async throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DirectE2BError.noApiKey }

        let executeURL = URL(string: "https://\(DirectE2BClient.codeInterpreterPort)-\(sandboxId).e2b.dev/execute")!
        var req = URLRequest(url: executeURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        if let token = accessToken {
            req.setValue(token, forHTTPHeaderField: "X-Access-Token")
        }
        req.timeoutInterval = TimeInterval(timeoutMs) / 1000
        let body: [String: Any] = ["code": code]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw DirectE2BError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DirectE2BError.stream("non-HTTP response from /execute")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DirectE2BError.http(status: http.statusCode, body: body)
        }
        // The /execute endpoint replies in NDJSON records; reconstruct
        // the script's plain stdout so every caller keeps parsing JSON
        // exactly as before.
        return Self.stdoutFromExecResponse(String(data: data, encoding: .utf8) ?? "")
    }

    /// Reconstruct a script's stdout from the code-interpreter
    /// `/execute` NDJSON response. Each line is one JSON record
    /// (`number_of_executions`, `stdout`, `result`, `error`, …);
    /// only `stdout` records contribute text. An `error` record
    /// contributes its `value` so failures read as messages instead
    /// of raw traceback dumps. Non-JSON lines pass through verbatim
    /// for forward-compat with a future raw-stream endpoint.
    static func stdoutFromExecResponse(_ raw: String) -> String {
        var out: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else {
                out.append(trimmed)
                continue
            }
            switch type {
            case "stdout":
                if let text = obj["text"] as? String, !text.isEmpty { out.append(text) }
                else if let text = obj["data"] as? String, !text.isEmpty { out.append(text) }
            case "error":
                if let value = obj["value"] as? String, !value.isEmpty { out.append(value) }
            default:
                break // execution_started / number_of_executions / result / status
            }
        }
        return out.joined(separator: "\n")
    }

    /// Expand one streaming `/execute` NDJSON record back into shim
    /// lines. The shim already prefixes its output with `STDOUT:` /
    /// `STDERR:` / `STEP:` / `EXIT:`; inside the NDJSON envelope that
    /// text sits in the `stdout` record, so we return its lines as-is
    /// and let `E2bPhoneStreamEvent.parse` demux them. `error`
    /// records surface their `value` as one `STDERR:` line. Records
    /// that carry no shim text, and non-JSON lines (raw shim output,
    /// future raw-stream modes), are handled with an empty / verbatim
    /// result respectively.
    static func expandStreamLine(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else {
            return trimmed.isEmpty ? [] : [line]
        }
        switch type {
        case "stdout":
            if let text = obj["text"] as? String, !text.isEmpty {
                return text.components(separatedBy: "\n")
            }
            return []
        case "stderr":
            if let text = obj["text"] as? String, !text.isEmpty {
                return text.components(separatedBy: "\n").map { "STDERR:" + $0 }
            }
            return []
        case "error":
            if let value = obj["value"] as? String, !value.isEmpty {
                return ["STDERR:" + value]
            }
            return []
        default:
            // execution_started / number_of_executions / result / status
            return []
        }
    }

    /// Run a shell command on a persistent sandbox and return
    /// `(stdout, stderr, exitCode)`. Convenience wrapper around
    /// `exec` that wraps `subprocess.run` for shell execution.
    public func runShell(
        sandboxId: String,
        accessToken: String?,
        command: String,
        cwd: String? = nil,
        timeoutSeconds: Int = 60,
    ) async throws -> ShellResult {
        let cwdLine = cwd.map { "cwd='\(escapePython($0))'; " } ?? ""
        let script = """
        import subprocess, json
        try:
            proc = subprocess.run(
                \(escapePython(command)),
                shell=True,
                cwd=\(cwdLine.replacingOccurrences(of: "cwd=", with: ""))None,
                capture_output=True,
                text=True,
                timeout=\(timeoutSeconds),
            )
            print(json.dumps({
                "stdout": proc.stdout,
                "stderr": proc.stderr,
                "exit_code": proc.returncode,
            }))
        except subprocess.TimeoutExpired as exc:
            print(json.dumps({
                "stdout": "",
                "stderr": f"timeout after {exc.timeout}s",
                "exit_code": 124,
            }))
        except Exception as exc:
            print(json.dumps({
                "stdout": "",
                "stderr": f"launch failed: {exc}",
                "exit_code": 125,
            }))
        """
        let raw = try await exec(sandboxId: sandboxId, accessToken: accessToken, code: script)
        // `exec` returns whatever the sandbox endpoint serialised;
        // the JSON we just printed is on the last non-empty line.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ShellResult(stdout: raw, stderr: "", exitCode: -1)
        }
        return ShellResult(
            stdout: parsed["stdout"] as? String ?? "",
            stderr: parsed["stderr"] as? String ?? "",
            exitCode: parsed["exit_code"] as? Int ?? -1
        )
    }

    /// Read a file from a persistent sandbox. Returns the file
    /// contents (UTF-8) or throws if the path doesn't exist.
    public func readFile(
        sandboxId: String,
        accessToken: String?,
        path: String,
    ) async throws -> String {
        let script = """
        import json, os
        try:
            with open(\(escapePython(path)), "r", encoding="utf-8") as f:
                content = f.read()
            print(json.dumps({"ok": True, "content": content}))
        except FileNotFoundError:
            print(json.dumps({"ok": False, "error": "file not found"}))
        except Exception as exc:
            print(json.dumps({"ok": False, "error": str(exc)}))
        """
        let raw = try await exec(sandboxId: sandboxId, accessToken: accessToken, code: script)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw DirectE2BError.stream("invalid readFile response: \(raw)")
        }
        if let ok = parsed["ok"] as? Bool, ok {
            return parsed["content"] as? String ?? ""
        }
        throw DirectE2BError.stream(parsed["error"] as? String ?? "read failed")
    }

    /// Write (or create) a file on a persistent sandbox.
    /// `mkdir -p` the parent directory first.
    public func writeFile(
        sandboxId: String,
        accessToken: String?,
        path: String,
        content: String,
    ) async throws {
        let script = """
        import json, os
        try:
            os.makedirs(os.path.dirname(\(escapePython(path))) or ".", exist_ok=True)
            with open(\(escapePython(path)), "w", encoding="utf-8") as f:
                f.write(\(escapePython(content)))
            print(json.dumps({"ok": True}))
        except Exception as exc:
            print(json.dumps({"ok": False, "error": str(exc)}))
        """
        let raw = try await exec(sandboxId: sandboxId, accessToken: accessToken, code: script)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw DirectE2BError.stream("writeFile failed: \(raw)")
        }
        if let ok = parsed["ok"] as? Bool, ok { return }
        let err = parsed["error"] as? String ?? raw
        throw DirectE2BError.stream("writeFile failed: \(err)")
    }

    /// Apply a unified-diff patch to a file on a persistent
    /// sandbox. Convenience helper for the agent loop's
    /// `edit_file` tool — takes the full file contents and
    /// writes them back, since a true patch applier is overkill
    /// for an MVP.
    public func writeFileFull(
        sandboxId: String,
        accessToken: String?,
        path: String,
        newContent: String,
    ) async throws {
        try await writeFile(
            sandboxId: sandboxId,
            accessToken: accessToken,
            path: path,
            content: newContent
        )
    }
}

/// Result of `runShell`. The stdout / stderr are the captured
/// streams from the subprocess; `exitCode` follows Unix
/// convention (0 = success, anything else = failure).
public struct ShellResult: Sendable, Hashable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int
    public var ok: Bool { exitCode == 0 }
}

/// Python-string escaping used by the exec helpers. Mirrors the
/// `PythonQuote.escape` in the shim builder so the phone-side
/// scripts and the shim agree on quoting rules.
private func escapePython(_ value: String) -> String {
    PythonQuote.escape(value)
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

    /// e2b.dev's `POST /sandboxes` reads `timeout` in **seconds** and
    /// rejects values over 1 hour ("Timeout can not be greater than
    /// 1 hours"). The public API stays millisecond-based
    /// (`timeoutMs`), so we keep the ms ceiling here and convert to
    /// seconds on the wire (`maxSandboxTimeoutSeconds`).
    public static let maxSandboxTimeoutMs: Int = 3_600_000
    /// e2b.dev's wire-level cap for `POST /sandboxes`: 3600 seconds.
    public static let maxSandboxTimeoutSeconds: Int = 3_600

    /// Create a fresh sandbox. Returns the e2b sandbox id and the
    /// "X-Access-Token" the sandbox returned; the token is needed to
    /// authenticate follow-up calls into the sandbox itself.
    ///
    /// `timeoutMs` is the sandbox lifetime in **milliseconds** and
    /// is clamped to `maxSandboxTimeoutMs` (1 hour) — e2b.dev's
    /// own limit. The wire value is sent in seconds
    /// (`timeoutMs / 1000`): sending the raw ms number makes the API
    /// reject the request. The default of 1 hour is right for
    /// long-lived code sessions where the user might run an agent
    /// loop for a while; one-shot runs can pass a smaller value.
    public func createSandbox(
        template: String = DirectE2BClient.codeInterpreterTemplate,
        timeoutMs: Int = 3_600_000,
    ) async throws -> E2bSandboxInfo {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DirectE2BError.noApiKey }
        // e2b.dev's hard cap. If the caller passed a longer value
        // (e.g. 7_200_000 for "2 hours") we silently cap it
        // rather than round-tripping a guaranteed 400. New sandboxes
        // beyond 1 hour require explicit re-provisioning.
        let safeTimeoutMs = min(max(0, timeoutMs), DirectE2BClient.maxSandboxTimeoutMs)

        var req = URLRequest(url: baseURL.appendingPathComponent("sandboxes"))
        req.httpMethod = "POST"
        req.setValue(trimmed, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "templateID": template,
            // e2b.dev validates this field in seconds (max 3_600), so
            // the ms value must be divided down before sending.
            "timeout": safeTimeoutMs / 1000,
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

    /// Keep a running sandbox alive by resetting its TTL.
    /// e2b.dev expires sandboxes N seconds after creation (or after the
    /// last timeout call), so long agent sessions call this on every
    /// user message and tool call — exactly the keep-alive the E2B
    /// design doc prescribes (`sandbox.setTimeout(...)` per step).
    ///
    /// - Parameter timeoutSeconds: TTL measured **from now**, in
    ///   seconds, clamped to `maxSandboxTimeoutSeconds` (1 hour for
    ///   Hobby accounts).
    /// - Returns: the HTTP status (200 on success).
    @discardableResult
    public func extendTimeout(
        sandboxId: String,
        timeoutSeconds: Int = DirectE2BClient.maxSandboxTimeoutSeconds,
    ) async throws -> Int {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DirectE2BError.noApiKey }
        let safe = min(max(0, timeoutSeconds), DirectE2BClient.maxSandboxTimeoutSeconds)

        var req = URLRequest(
            url: baseURL
                .appendingPathComponent("sandboxes")
                .appendingPathComponent(sandboxId)
                .appendingPathComponent("timeout")
        )
        req.httpMethod = "POST"
        req.setValue(trimmed, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["timeout": safe])

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
                // Same NDJSON envelope as `exec`: the shim's
                // `STDOUT:` / `STEP:` markers ride inside the
                // `stdout` record text. Expand each record back
                // into shim lines so the parser below is untouched;
                // raw (non-JSON) lines pass through verbatim.
                for shimLine in Self.expandStreamLine(line) {
                    switch E2bPhoneStreamEvent.parse(line: shimLine) {
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
                        // The shim's only `EXIT:` emission is the final
                        // process exit code for the user step. Per-step
                        // failures arrive as `STEP:<id>:failed:N` (handled
                        // above) and short-circuit the run before we
                        // ever see the EXIT line.
                        exitCode = code
                    case let .passthrough(raw):
                        // Forward-compat for any future shim output the
                        // parser doesn't recognise — show it as stdout so
                        // the user doesn't lose the line.
                        onEvent(.log(stream: "stdout", line: raw, stepId: currentStepId))
                    }
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
///
/// Internal because the only legitimate consumer is the `run()` loop
/// in this file. The static `parse` function is `internal` too, so
/// the unit tests in the same target can exercise it directly.
enum E2bPhoneStreamEvent: Sendable, Hashable {
    case stdout(String)
    case stderr(String)
    /// Process exit code. `nil` exit means the stream ended before
    /// the shim sent an EXIT line — usually a sandbox crash.
    case exit(Int)
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

    /// Pure parser. `internal` so unit tests in the same target can
    /// drive it without exposing the wire format on the public API.
    static func parse(line: String) -> E2bPhoneStreamEvent {
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
            // The shim only emits `emit("exit", str(user_code))` —
            // the per-step failures are now reported as
            // `STEP:<id>:failed:N`, not as `EXIT:<error>`. Any
            // `EXIT:` line is therefore the final process exit code.
            return .exit(Int(value) ?? -1)
        default:
            return .passthrough(line)
        }
    }
}
