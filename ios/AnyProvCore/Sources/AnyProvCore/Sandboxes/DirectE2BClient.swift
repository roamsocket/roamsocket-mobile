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
/// Wiring note: the iOS app talks to the *base* sandbox template via
/// envd's `process.Process/Start` Connect-RPC endpoint. We don't use the
/// code-interpreter template's `/execute` anymore — that path was a
/// Python shim that ran inside a Jupyter kernel, and the kernel's
/// auto-indent prepended env-var code to our script, which was the
/// source of the "invalid syntax" failures on first run. The envd
/// `bash -l -c "<script>"` route takes a plain string and runs it as a
/// real shell, so the clone + checkout + user command all flow through
/// the envd HTTP API with no Python involved.
public final class DirectE2BClient: @unchecked Sendable {
    /// e2b's API host. Public — the desktop runner uses the same one.
    public static let apiHost = "api.e2b.dev"
    /// envd is the daemon inside every sandbox. It speaks Connect-RPC on
    /// this port and is the canonical way to run shell commands.
    public static let envdPort = 49_983
    /// `base` is the default e2b template; it's the smallest envd-only
    /// image and has `git`, `bash`, etc. preinstalled.
    public static let defaultTemplate = "base"
    /// Connect-RPC streaming endpoint inside the sandbox.
    public static let processStartPath = "/process.Process/Start"

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
    public func createSandbox(template: String = DirectE2BClient.defaultTemplate, timeoutSeconds: Int = 600) async throws -> E2bSandboxInfo {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DirectE2BError.noApiKey }

        var req = URLRequest(url: baseURL.appendingPathComponent("sandboxes"))
        req.httpMethod = "POST"
        req.setValue(trimmed, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        // The e2b REST API takes `timeout` in *seconds*, not
        // milliseconds. The hard cap is 1 hour; clamp anything larger
        // so we never burn the user a 24-hour sandbox by accident.
        let clamped = max(60, min(timeoutSeconds, 3_600))
        let body: [String: Any] = [
            "templateID": template,
            "timeout": clamped,
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

    // MARK: - Run a shell command via envd

    /// Build the shell snippet that clones `repo`, checks out `branch`,
    /// and runs `command`. Returns the raw string passed to
    /// `bash -l -c` — no Python involved.
    ///
    /// Behaviour notes:
    ///   * `--depth 1` keeps the clone cheap on the e2b VM.
    ///   * We always fetch the requested branch shallowly, because the
    ///     initial `--depth 1` clone only checks out the repo's default
    ///     branch. Without the second fetch, a non-default branch would
    ///     fail `git checkout` with "reference not found".
    ///   * Each step exits early on failure so we never silently run
    ///     the user's command on top of a half-cloned repo.
    ///   * The script is plain bash — it goes through envd unchanged.
    internal static func buildShellScript(repo: E2bPhoneRepoSelection, branch: String, command: String, githubToken: String?) -> String {
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
        return """
        set -e
        rm -rf /code
        git clone --depth 1 \(ShellQuote.escape(cloneURL)) /code
        cd /code
        git fetch --depth 1 origin \(ShellQuote.escape(branch))
        git checkout \(ShellQuote.escape(branch))
        \(command)
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
            sandbox = try await createSandbox(template: DirectE2BClient.defaultTemplate, timeoutSeconds: 600)
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

        // 2. POST the shell script to envd's process.Process/Start and
        //    stream back the Connect-RPC envelopes.
        let script = DirectE2BClient.buildShellScript(
            repo: request.repo,
            branch: request.branch,
            command: request.command,
            githubToken: request.githubToken,
        )
        let startURL = URL(string: "https://\(DirectE2BClient.envdPort)-\(sandbox.sandboxId).\(sandbox.domain)\(DirectE2BClient.processStartPath)")!
        var req = URLRequest(url: startURL)
        req.httpMethod = "POST"
        req.setValue("application/connect+json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        if let token = sandbox.accessToken {
            req.setValue(token, forHTTPHeaderField: "X-Access-Token")
        }
        // Connect envelope: 1 byte flags + 4 bytes big-endian length + JSON.
        // Flags byte 0 = no compression, not end-of-stream.
        let body: [String: Any] = [
            "process": [
                "cmd": "/bin/bash",
                "args": ["-l", "-c", script],
            ],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        req.httpBody = ConnectEnvelope.wrap(json)

        let session = URLSession.shared
        var exitCode: Int?
        var streamError: String?
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw DirectE2BError.stream("start HTTP \(code)")
            }
            for try await event in ConnectEnvelope.stream(bytes) {
                switch event {
                case .start(let pid):
                    onEvent(.log(stream: "stdout", line: "Started pid \(pid)"))
                case let .data(stream, text):
                    onEvent(.log(stream: stream, line: text))
                case let .end(code, rawStatus):
                    exitCode = code
                    // envd only sets `status` to a non-empty string on
                    // abnormal termination; an `"exit status 0"` is
                    // success, but anything else is worth surfacing.
                    if let rawStatus, !rawStatus.isEmpty,
                       !rawStatus.hasPrefix("exit status 0") {
                        streamError = rawStatus
                    }
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

// MARK: - Connect streaming envelope

/// Connect-RPC streaming uses a 5-byte envelope per message: 1 byte
/// bitwise flags + 4 bytes big-endian message length, followed by the
/// message payload (JSON for `application/connect+json`). Bit 0 of
/// the flags byte = compressed (we never set it). Bit 1 = end-of-stream
/// (set on the final envelope, with no payload).
///
/// See https://connectrpc.com/docs/protocol/ — the envelope layout is
/// identical across connect-go, connect-web, and the envd daemon.
enum ConnectEnvelope {
    static let flagEndStream: UInt8 = 0b0000_0010

    /// Wrap a single request body in the 5-byte Connect envelope.
    static func wrap(_ payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(0) // flags = 0 (uncompressed, not end-of-stream)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    enum Event {
        case start(pid: Int)
        /// Decoded text from one chunk. The e2b SDK uses incremental
        /// UTF-8 decoding and treats bytes as `text/plain`, so we
        /// convert the bytes to a String lossily here — partial
        /// sequences at chunk boundaries surface as replacement chars,
        /// which is the same behaviour the official SDK documents.
        case data(stream: String, text: String)
        /// End-of-process from envd. `exitCode` is the parsed integer
        /// (positive for `exit status N`, negated for `signal: N`).
        /// `rawStatus` is the original `"exit status 0"` / `"signal: 9"`
        /// string, kept for debugging.
        case end(exitCode: Int?, rawStatus: String?)
    }

    /// Parse a stream of Connect envelopes out of `bytes`. Yields one
    /// `Event` per envelope and finishes on the end-of-stream marker
    /// or on a clean end-of-stream.
    static func stream(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        while let event = try parseNextEvent(from: &buffer) {
                            if case .end = event {
                                continuation.yield(event)
                                continuation.finish()
                                return
                            }
                            continuation.yield(event)
                        }
                    }
                    // Server closed the stream without an end marker —
                    // surface as a soft end so callers can still report
                    // exit code 0 if data came through.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pull one fully-formed envelope off the front of `buffer` and
    /// return its decoded event. Returns `nil` if there isn't a full
    /// envelope yet.
    private static func parseNextEvent(from buffer: inout Data) throws -> Event? {
        guard buffer.count >= 5 else { return nil }
        let flags = buffer[0]
        let length = (UInt32(buffer[1]) << 24)
            | (UInt32(buffer[2]) << 16)
            | (UInt32(buffer[3]) << 8)
            | UInt32(buffer[4])
        let total = 5 + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: 5..<total)
        buffer.removeSubrange(0..<total)
        if flags & flagEndStream != 0 {
            return .end(exitCode: nil, rawStatus: nil)
        }
        return try decode(payload)
    }

    /// Test-only wrapper so `DirectE2BClientTests` can drive the same
    /// parser the production code uses, against captured real envd
    /// responses.
    internal static func parseNextEventForTest(from buffer: inout Data) throws -> Event? {
        try parseNextEvent(from: &buffer)
    }

    private static func decode(_ payload: Data) throws -> Event {
        let json = try JSONSerialization.jsonObject(with: payload)
        // The Connect envelope wraps the protobuf JSON in a top-level
        // `event` object, and inside that the actual `ProcessEvent`
        // oneof. We unroll it here without a protobuf dep.
        guard let outer = json as? [String: Any],
              let event = outer["event"] as? [String: Any] else {
            throw DirectE2BError.stream("unexpected envd envelope: missing event")
        }
        if let start = event["start"] as? [String: Any] {
            let pid = (start["pid"] as? NSNumber)?.intValue ?? 0
            return .start(pid: pid)
        }
        // Empirically (envd 0.6.x on a `base` sandbox, smoke test
        // 2026-09-01), the `data` event has the stream name directly
        // as a key under `event.data` — there is no `output` wrapper
        // in the JSON envelope, even though the proto source shows
        // one. We accept both shapes so a future envd release with
        // the wrapper doesn't break us.
        if let data = event["data"] as? [String: Any] {
            if let (streamKey, raw) = decodeStreamField(in: data) {
                return .data(stream: streamKey, text: decodeBytes(raw))
            }
        }
        if let end = event["end"] as? [String: Any] {
            // Empirically: envd returns `{"exited": true, "status":
            // "exit status 0"}` (or `"signal: 9"` for signalled
            // processes). The `exitCode` field shown in the e2b
            // Python SDK is computed locally from this string.
            let status = end["status"] as? String
            let exited = (end["exited"] as? NSNumber)?.boolValue
            return .end(
                exitCode: parseExitStatus(status, exited: exited),
                rawStatus: status,
            )
        }
        throw DirectE2BError.stream("unknown envd event: \(event.keys.sorted())")
    }

    /// Look up `stdout` / `stderr` / `pty` in either the new flat shape
    /// (`event.data.stdout = "<base64>"`) or the proto-with-wrapper
    /// shape (`event.data.output.stdout = "<base64>"`). Returns
    /// `nil` if none of the three is set.
    private static func decodeStreamField(in data: [String: Any]) -> (String, Any)? {
        if let raw = data["stdout"] { return ("stdout", raw) }
        if let raw = data["stderr"] { return ("stderr", raw) }
        if let raw = data["pty"] { return ("pty", raw) }
        if let output = data["output"] as? [String: Any] {
            if let raw = output["stdout"] { return ("stdout", raw) }
            if let raw = output["stderr"] { return ("stderr", raw) }
            if let raw = output["pty"] { return ("pty", raw) }
        }
        return nil
    }

    /// Parse envd's human-readable status string into an integer exit
    /// code. We negate signal codes so a signalled process is reported
    /// with a negative number, matching the convention the e2b JS
    /// SDK uses.
    static func parseExitStatus(_ status: String?, exited: Bool?) -> Int? {
        guard exited == true, let status, !status.isEmpty else { return nil }
        // "exit status 0" / "exit status 1" / …
        if let n = intAfter(prefix: "exit status ", in: status) {
            return n
        }
        // "signal: 9" / "signal: SIGKILL" — envd's Go side reports the
        // signal name sometimes and the number other times.
        if let n = intAfter(prefix: "signal: ", in: status) {
            return -n
        }
        return nil
    }

    private static func intAfter(prefix: String, in s: String) -> Int? {
        guard s.hasPrefix(prefix) else { return nil }
        let tail = s.dropFirst(prefix.count)
        // Strip a possible trailing reason like "exit status 1 (boom)".
        let head = tail.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
        return Int(head)
    }

    private static func decodeBytes(_ raw: Any) -> String {
        if let s = raw as? String {
            // e2b's connect+json path uses base64 because the field
            // is `bytes` in the proto. Decode, then take the UTF-8
            // view. The official SDK uses an incremental decoder that
            // surfaces partial sequences as U+FFFD; we approximate
            // that with `String(decoding:as:)` which is loss-free for
            // complete chunks and replaces invalid bytes for partials.
            if let data = Data(base64Encoded: s) {
                return String(decoding: data, as: UTF8.self)
            }
            return s
        }
        if let data = raw as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        return ""
    }
}

/// Single-quoted shell escape. `bash -l -c` doesn't go through another
/// level of escaping, so this is the safe shape: wrap in single quotes
/// and close+escape+reopen for any embedded single quote.
enum ShellQuote {
    static func escape(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_-./:=@%+,~"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
