import XCTest
@testable import AnyProvCore

final class DirectE2BClientTests: XCTestCase {
    // MARK: - PythonQuote

    /// Every value lands inside single quotes. The old "safe char"
    /// short-circuit was the root cause of the pre-clone
    /// `invalid syntax (481837546.py, line 3)` error: a clone URL
    /// such as `https://github.com/owner/repo.git` only contains
    /// alphanumerics + `:` / `/` / `.`, all of which the old
    /// implementation treated as "safe" and emitted unquoted, so the
    /// generated Python source became `clone_url = https://...` —
    /// a syntax error. Always quote.
    func testPythonQuoteAlwaysQuotes() {
        XCTAssertEqual(PythonQuote.escape("hello"), "'hello'")
        XCTAssertEqual(PythonQuote.escape("/usr/local/bin"), "'/usr/local/bin'")
        XCTAssertEqual(PythonQuote.escape("npm-test"), "'npm-test'")
        XCTAssertEqual(PythonQuote.escape("v1.2.3"), "'v1.2.3'")
    }

    /// Branch names and clone URLs are the actual values spliced into
    /// the pre-clone / shim Python source. They must come out quoted
    /// so the script is valid Python.
    func testPythonQuoteQuotesUrlsAndBranches() {
        let url = "https://github.com/owner/repo.git"
        let branch = "feat/cool-thing"
        XCTAssertEqual(
            PythonQuote.escape(url),
            "'https://github.com/owner/repo.git'",
            "clone URL must be wrapped so the embedded `:` and `/` are not parsed as Python operators"
        )
        XCTAssertEqual(
            PythonQuote.escape(branch),
            "'feat/cool-thing'",
            "branch name must be wrapped so the `/` is not a division"
        )
    }

    func testPythonQuoteWrapsSpacesInSingleQuotes() {
        XCTAssertEqual(PythonQuote.escape("npm test"), "'npm test'")
    }

    func testPythonQuoteEscapesEmbeddedSingleQuotes() {
        // CPython shlex.quote: ' -> '"'"'
        XCTAssertEqual(PythonQuote.escape("it's"), "'it'\"'\"'s'")
    }

    func testPythonQuoteEmptyBecentsEmptyQuoted() {
        XCTAssertEqual(PythonQuote.escape(""), "''")
    }

    // MARK: - Pre-clone / shim script validity (PythonQuote fix)

    /// The pre-clone script is the original "invalid syntax
    /// (481837546.py, line 3)" failure site: it interpolated
    /// `clone_url = <PythonQuote.escape(url)>` and the URL came out
    /// unquoted, so the very first `git clone` line raised
    /// `SyntaxError` and the session fell back to "the agent can
    /// run `git clone` itself". Lock the script: every value we
    /// splice into an assignment must be a quoted Python literal.
    func testPreCloneScriptIsSyntacticallyValidPython() {
        let url = "https://github.com/owner/repo.git"
        let branch = "feat/cool-thing"
        // The script is built inline in E2bSessionStore; instead of
        // exposing it (it isn't public), we reproduce the exact
        // interpolation pattern and assert the substitution is
        // quoted. If `PythonQuote.escape` ever regresses, this test
        // fails before the script is even handed to e2b.
        let cloneLine = "clone_url = \(PythonQuote.escape(url))"
        let branchLine = "branch = \(PythonQuote.escape(branch))"
        XCTAssertTrue(
            cloneLine.contains("clone_url = 'https://github.com/owner/repo.git'"),
            "clone URL assignment must be a quoted Python literal; got: \(cloneLine)"
        )
        XCTAssertFalse(
            cloneLine.contains("clone_url = https://"),
            "clone URL must NOT be interpolated as a bare expression"
        )
        XCTAssertTrue(
            branchLine.contains("branch = 'feat/cool-thing'"),
            "branch assignment must be a quoted Python literal; got: \(branchLine)"
        )
        XCTAssertFalse(
            branchLine.contains("branch = feat/"),
            "branch must NOT be interpolated as a bare expression (the `/` would be parsed as division)"
        )
    }

    /// The pre-clone script is intentionally a flat module body
    /// (no function wrapper) so e2b's `/execute` endpoint can run
    /// it as-is. That means `return` is **not** valid at the
    /// short-circuit points — Python would raise
    /// `'return' outside function`, the exact error users saw
    /// after the URL-quoting fix landed. The script must use
    /// `sys.exit(0)` for those early exits. We assert on the
    /// actual source string in `E2bSessionStore.swift` so a
    /// regression trips the test instead of just the user.
    func testPreCloneScriptShortCircuitsWithSysExitNotReturn() throws {
        // Locate the package source file. The test runs in the
        // AnyProvCore SPM target, so the App-level `E2bSessionStore`
        // isn't in the same module — we read the file directly
        // from the repo so the test is independent of the iOS
        // app's build status.
        let repoRoot = Self.repoRoot()
        let sourcePath = repoRoot
            .appendingPathComponent("ios")
            .appendingPathComponent("App")
            .appendingPathComponent("Sources")
            .appendingPathComponent("Features")
            .appendingPathComponent("Code")
            .appendingPathComponent("E2BCodeSession")
            .appendingPathComponent("E2bSessionStore.swift")
        let source = try String(
            contentsOf: sourcePath,
            encoding: .utf8
        )
        // Find the script literal in `preCloneRepo`. The block
        // opens with `import subprocess, json, sys` (the full
        // import line, not just the prefix — anchoring on the
        // prefix would land `upperBound` *before* the trailing
        // `import sys` and the slice would lose it) and closes
        // with the trailing `"""` of the multiline string. We
        // grab everything between so the assertions below
        // operate on the actual Python source.
        let importLine = "import subprocess, json, sys"
        guard let openRange = source.range(of: importLine),
              let closeRange = source.range(
                of: "\"\"\"",
                range: openRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("could not locate the pre-clone script in \(sourcePath.path)")
            return
        }
        let script = String(source[openRange.lowerBound..<closeRange.lowerBound])

        // The literal `import sys` isn't a substring of the
        // composite `import subprocess, json, sys` line, so check
        // the full line — that's the actual contract the
        // pre-clone script must satisfy.
        XCTAssertTrue(
            script.contains(importLine),
            "pre-clone script must keep the `\(importLine)` import; the body is module-level, so the only valid early-exit is `sys.exit(...)`. script=\(script)"
        )
        // Two short-circuit sites (clone failure, checkout
        // failure). Each must be `sys.exit(0)`, not bare
        // `return`. Count occurrences of each so a regression
        // either direction shows up clearly.
        let sysExitCount = script.components(separatedBy: "sys.exit").count - 1
        let bareReturnCount = script.components(separatedBy: "\n        return").count - 1
            + script.components(separatedBy: "\n            return").count - 1
        XCTAssertGreaterThanOrEqual(
            sysExitCount, 2,
            "pre-clone script must call `sys.exit(...)` at least twice (clone failure, checkout failure); found \(sysExitCount)"
        )
        XCTAssertEqual(
            bareReturnCount, 0,
            "pre-clone script must not use bare `return` at module level (causes `'return' outside function`); found \(bareReturnCount)"
        )
    }

    /// Walk up from the test bundle until we find the repo root
    /// (the directory that contains the `ios/` subdir). Falls
    /// back to the current working directory if no `ios/`
    /// ancestor is in the chain — keeps the test runnable from
    /// a future SPM-based layout where the path changes.
    private static func repoRoot() -> URL {
        // The test file lives at
        //   <repo>/ios/AnyProvCore/Tests/AnyProvCoreTests/...
        // so going up 4 levels lands on the repo root. We
        // search upward for the first directory that has an
        // `ios/` child to be robust against any future layout
        // change.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("ios").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// Same regression lock for the long-lived code-session shim.
    /// `makeShimScript` interpolates branch / URL / command /
    /// install command the same way. If PythonQuote regresses, the
    /// shim becomes invalid Python and the session never gets past
    /// `import`.
    func testShimScriptQuotesAllInterpolatedStrings() {
        let script = DirectE2BClient.makeShimScript(
            repo: .github(fullName: "owner/repo"),
            branch: "main",
            command: "npm test",
            githubToken: nil
        )
        // Each assignment must produce a quoted literal.
        XCTAssertTrue(
            script.contains("clone_url = 'https://github.com/owner/repo.git'"),
            "shim clone URL must be quoted; got a sample: \(Self.first(containing: "clone_url", in: script) ?? "<missing>")"
        )
        XCTAssertTrue(
            script.contains("branch = 'main'"),
            "shim branch must be quoted; got a sample: \(Self.first(containing: "branch =", in: script) ?? "<missing>")"
        )
        XCTAssertTrue(
            script.contains("user_cmd = 'npm test'"),
            "shim user command must be quoted; got a sample: \(Self.first(containing: "user_cmd =", in: script) ?? "<missing>")"
        )
        // Bare-expression forms must NOT appear anywhere in the
        // script (these are the exact patterns that produced the
        // "line 3" SyntaxError).
        XCTAssertFalse(
            script.contains("clone_url = https://"),
            "shim must not interpolate the URL as a bare expression"
        )
        XCTAssertFalse(
            script.contains("branch = main\n") || script.contains("branch = main "),
            "shim must not interpolate the branch as a bare identifier"
        )
        XCTAssertFalse(
            script.contains("user_cmd = npm test"),
            "shim must not interpolate the user command as a bare expression"
        )
    }

    private static func first(containing needle: String, in haystack: String) -> String? {
        guard let r = haystack.range(of: needle) else { return nil }
        let end = haystack.index(r.lowerBound, offsetBy: 120, limitedBy: haystack.endIndex) ?? haystack.endIndex
        return String(haystack[r.lowerBound..<end])
    }

    // MARK: - /execute NDJSON unwrapping

    func testStdoutFromExecResponseCollectsStdoutRecords() {
        let raw = #"""
        {"type": "number_of_executions", "execution_count": 1}
        {"type": "stdout", "text": "{\"ok\": true, \"sha\": \"abc\"}"}
        {"type": "result", "content_type": "application/json", "data": {}}
        {"type": "status", "status": "completed"}
        """#
        XCTAssertEqual(
            DirectE2BClient.stdoutFromExecResponse(raw),
            #"{"ok": true, "sha": "abc"}"#
        )
    }

    func testStdoutFromExecResponseSurfacesErrorValue() {
        let raw = """
        {"type": "number_of_executions", "execution_count": 1}
        {"type": "error", "name": "SyntaxError", "value": "invalid syntax (481837546.py, line 3)", "traceback": []}
        """
        XCTAssertEqual(
            DirectE2BClient.stdoutFromExecResponse(raw),
            "invalid syntax (481837546.py, line 3)"
        )
    }

    func testStdoutFromExecResponsePassesThroughNonJSON() {
        XCTAssertEqual(DirectE2BClient.stdoutFromExecResponse("plain\ntext"), "plain\ntext")
    }

    func testExpandStreamLineUnwrapsNDJSONStdout() {
        let line = #"{"type": "stdout", "text": "STDOUT:hello\nSTDOUT:world"}"#
        XCTAssertEqual(
            DirectE2BClient.expandStreamLine(line),
            ["STDOUT:hello", "STDOUT:world"]
        )
    }

    func testExpandStreamLineSurfacesErrorAsStderr() {
        let line = #"{"type": "error", "name": "SyntaxError", "value": "bad syntax"}"#
        XCTAssertEqual(
            DirectE2BClient.expandStreamLine(line),
            ["STDERR:bad syntax"]
        )
    }

    func testExpandStreamLinePassthroughForRawLines() {
        XCTAssertEqual(
            DirectE2BClient.expandStreamLine("STDOUT:as-is"),
            ["STDOUT:as-is"]
        )
        XCTAssertEqual(DirectE2BClient.expandStreamLine(""), [])
    }

    // MARK: - E2bPhoneStreamEvent.parse

    func testStreamParseStdout() {
        XCTAssertEqual(E2bPhoneStreamEvent.parse(line: "STDOUT:hello world"), .stdout("hello world"))
    }

    func testStreamParseStderr() {
        XCTAssertEqual(E2bPhoneStreamEvent.parse(line: "STDERR:something broke"), .stderr("something broke"))
    }

    func testStreamParseExitZero() {
        XCTAssertEqual(E2bPhoneStreamEvent.parse(line: "EXIT:0"), .exit(0))
    }

    func testStreamParseExitNonZero() {
        XCTAssertEqual(E2bPhoneStreamEvent.parse(line: "EXIT:1"), .exit(1))
        XCTAssertEqual(E2bPhoneStreamEvent.parse(line: "EXIT:127"), .exit(127))
    }

    /// The old shim used `EXIT:clone-failed:<n>` etc. for fatal
    /// errors. The new shim only emits `EXIT:<code>` for the final
    /// process exit; per-step failures arrive as `STEP:<id>:failed:N`.
    /// Lock the new behaviour: the parser drops any non-integer
    /// EXIT payload to the `-1` sentinel. A regression that
    /// resurrects the old format would surface as a phantom
    /// `.exit(-1)` plus a missing `STEP:<id>:failed:N` event.
    func testStreamParseExitAlwaysMapsToExitCode() {
        XCTAssertEqual(
            E2bPhoneStreamEvent.parse(line: "EXIT:clone-failed:128"),
            .exit(-1)
        )
        XCTAssertEqual(
            E2bPhoneStreamEvent.parse(line: "EXIT:checkout-failed"),
            .exit(-1)
        )
        XCTAssertEqual(
            E2bPhoneStreamEvent.parse(line: "EXIT:launch-failed"),
            .exit(-1)
        )
    }

    func testStreamParseUnknownPrefixIsPassthrough() {
        XCTAssertEqual(
            E2bPhoneStreamEvent.parse(line: "WARN:deprecated endpoint"),
            .passthrough("WARN:deprecated endpoint")
        )
    }

    func testStreamParseNoSeparatorIsPassthrough() {
        XCTAssertEqual(
            E2bPhoneStreamEvent.parse(line: "raw log line"),
            .passthrough("raw log line")
        )
    }

    // MARK: - makeShimScript

    func testShimClonesPublicRepoWithoutToken() {
        let script = DirectE2BClient.makeShimScript(
            repo: .github(fullName: "owner/repo"),
            branch: "main",
            command: "npm test",
            githubToken: nil
        )
        XCTAssertTrue(script.contains("https://github.com/owner/repo.git"), script)
        XCTAssertFalse(script.contains("oauth2:"), script)
    }

    func testShimInjectsTokenForPrivateRepo() {
        let script = DirectE2BClient.makeShimScript(
            repo: .github(fullName: "owner/private"),
            branch: "main",
            command: "npm test",
            githubToken: "ghp_secretToken"
        )
        XCTAssertTrue(script.contains("oauth2:ghp_secretToken@github.com/owner/private.git"), script)
    }

    func testShimUsesRawUrlWhenProvided() {
        let script = DirectE2BClient.makeShimScript(
            repo: .url("https://example.com/my.git"),
            branch: "main",
            command: "echo hi",
            githubToken: nil
        )
        XCTAssertTrue(script.contains("https://example.com/my.git"), script)
    }

    func testShimIgnoresEmptyToken() {
        let script = DirectE2BClient.makeShimScript(
            repo: .github(fullName: "owner/repo"),
            branch: "main",
            command: "echo hi",
            githubToken: ""
        )
        XCTAssertTrue(script.contains("https://github.com/owner/repo.git"), script)
        XCTAssertFalse(script.contains("oauth2:"), script)
    }

    /// The "git build method after pushing" invariant. The shim must
    /// always re-fetch the target branch tip after the initial clone,
    /// because a depth-1 clone only grabs the default branch's HEAD.
    /// If the user just `git push`-ed a new commit on a feature
    /// branch, the clone is stale and the build would otherwise run
    /// against the wrong commit.
    func testShimRefetchesTargetBranchTipAfterShallowClone() {
        let script = DirectE2BClient.makeShimScript(
            repo: .github(fullName: "owner/repo"),
            branch: "feat/new-thing",
            command: "npm test",
            githubToken: nil
        )
        // The fetch must target the requested branch, not "main".
        XCTAssertTrue(script.contains("fetch"), "shim should git fetch the target branch")
        XCTAssertTrue(
            script.contains("origin") && script.contains("feat/new-thing"),
            "shim should git fetch origin feat/new-thing"
        )
        // And the checkout must follow the fetch.
        XCTAssertTrue(
            script.contains("checkout") && script.contains("feat/new-thing"),
            "shim should git checkout feat/new-thing"
        )
    }

    /// Fail loudly on fetch errors. The original implementation
    /// silently logged stderr and continued, which let builds run
    /// against a stale clone. We now abort the clone step on a
    /// non-zero fetch exit.
    func testShimAbortsOnFetchError() {
        let script = DirectE2BClient.makeShimScript(
            repo: .github(fullName: "owner/repo"),
            branch: "feat/missing",
            command: "npm test",
            githubToken: nil
        )
        // The script must inspect the fetch return code and bail
        // out (step_failed + sys.exit) when it fails.
        XCTAssertTrue(
            script.contains("fetch.returncode"),
            "shim must check git fetch's return code"
        )
        XCTAssertTrue(
            script.contains("step_failed(\"clone\""),
            "shim must mark the clone step failed on fetch error"
        )
    }

    /// After checkout, the shim logs the resolved HEAD so the user
    /// can see exactly which commit was built. This is the smoking
    /// gun if "after pushing" ever fails to pick up the new commit.
    func testShimLogsResolvedHead() {
        let script = DirectE2BClient.makeShimScript(
            repo: .github(fullName: "owner/repo"),
            branch: "main",
            command: "echo hi",
            githubToken: nil
        )
        XCTAssertTrue(
            script.contains("rev-parse"),
            "shim should run git rev-parse to surface the resolved commit"
        )
        XCTAssertTrue(
            script.contains("HEAD:"),
            "shim should print a 'HEAD: <sha>' line so the user can see the build target"
        )
    }

    func testShimEscapesBranchAndCommand() {
        // A branch / command with shell metacharacters must be
        // shlex-quoted so the user's input can't escape the shell.
        let script = DirectE2BClient.makeShimScript(
            repo: .github(fullName: "owner/repo"),
            branch: "feat/x; rm -rf /",
            command: "echo $(whoami) && cat /etc/passwd",
            githubToken: nil
        )
        // The branch should land inside Python single quotes; the
        // metacharacters themselves should be inside the quoted
        // string, not interpreted by the outer shell.
        XCTAssertTrue(script.contains("'feat/x; rm -rf /'"), script)
        XCTAssertTrue(script.contains("'echo $(whoami) && cat /etc/passwd'"), script)
    }

    func testShimEmitsAllThreePrefixes() {
        // The shim's emit() prefixes each line with `STDOUT:` /
        // `STDERR:` / `EXIT:` (computed via .upper() on the label
        // argument) so the phone-side parser can demux the stream.
        // We assert the source contains the lower-case labels
        // passed to emit() AND that the .upper() in the f-string
        // turns them into the on-the-wire prefix.
        let script = DirectE2BClient.makeShimScript(
            repo: .github(fullName: "owner/repo"),
            branch: "main",
            command: "true",
            githubToken: nil
        )
        // The labels "stdout" / "stderr" appear as string literals
        // in the script (used to spawn the pump threads).
        XCTAssertTrue(script.contains("\"stdout\""), script)
        XCTAssertTrue(script.contains("\"stderr\""), script)
        // "exit" is the label passed to emit() for the terminal
        // status line. We assert both the literal "exit" string and
        // that emit() is called with it.
        XCTAssertTrue(script.contains("emit(\"exit\""), script)
        // The f-string `f"{stream.upper()}:{line}"` produces the
        // STDOUT/STDERR/EXIT: prefix at runtime.
        XCTAssertTrue(script.contains(".upper()}:"), script)
    }

    // MARK: - createSandbox

    func testCreateSandboxPostsApiKeyAndParsesId() async throws {
        let http = MockHTTPClient(routes: [(
            match: "/sandboxes",
            status: 200,
            body: json(#"{"sandboxID":"sb_abc123","clientID":"cli_xyz","envdVersion":"0.1.0"}"#)
        )])
        let client = DirectE2BClient(apiKey: "e2b_testkey1234567890abcdef", http: http)
        let info = try await client.createSandbox()
        XCTAssertEqual(info.sandboxId, "sb_abc123")
        XCTAssertEqual(info.template, DirectE2BClient.codeInterpreterTemplate)
    }

    func testCreateSandboxWithoutApiKeyThrows() async {
        let client = DirectE2BClient(
            apiKey: "   ",
            http: MockHTTPClient(routes: []),
        )
        do {
            _ = try await client.createSandbox()
            XCTFail("Expected noApiKey")
        } catch DirectE2BError.noApiKey {
            // expected
        } catch {
            XCTFail("Expected noApiKey, got \(error)")
        }
    }

    func testCreateSandboxSurfacesHttpError() async {
        let http = MockHTTPClient(routes: [(
            match: "/sandboxes",
            status: 401,
            body: json(#"{"message":"unauthorized"}"#)
        )])
        let client = DirectE2BClient(
            apiKey: "e2b_badkey1234567890abcdef",
            http: http
        )
        do {
            _ = try await client.createSandbox()
            XCTFail("Expected http error")
        } catch let DirectE2BError.http(status, body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("unauthorized"))
        } catch {
            XCTFail("Expected http error, got \(error)")
        }
    }

    func testCreateSandboxSurfacesTransportError() async {
        final class FailingHTTP: HTTPClient, @unchecked Sendable {
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                throw NSError(domain: "test", code: -1001)
            }
        }
        let client = DirectE2BClient(
            apiKey: "e2b_testkey1234567890abcdef",
            http: FailingHTTP()
        )
        do {
            _ = try await client.createSandbox()
            XCTFail("Expected transport error")
        } catch let DirectE2BError.transport(msg) {
            XCTAssertFalse(msg.isEmpty)
        } catch {
            XCTFail("Expected transport error, got \(error)")
        }
    }

    /// e2b.dev rejects `timeout` values over 1 hour with a
    /// confusing server-side error ("Timeout can not be greater
    /// than 1 hours"). The client clamps to the ceiling and sends
    /// the value in **seconds**. Verify via the captured request
    /// body: a 2-hour (7,200,000 ms) timeout must arrive as
    /// 3,600 seconds, not 3,600,000.
    func testCreateSandboxClampsTimeoutToOneHour() async throws {
        final class CapturingHTTP: HTTPClient, @unchecked Sendable {
            var capturedBody: Data?
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                capturedBody = request.httpBody
                return (
                    json(#"{"sandboxID":"sb_abc","clientID":"cli_xyz"}"#),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        }
        let cap = CapturingHTTP()
        let client = DirectE2BClient(
            apiKey: "e2b_testkey1234567890abcdef",
            http: cap
        )
        // Caller asks for 2 hours (7,200,000 ms).
        _ = try await client.createSandbox(timeoutMs: 7_200_000)
        let body = try XCTUnwrap(cap.capturedBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let timeout = try XCTUnwrap(obj["timeout"] as? Int)
        XCTAssertEqual(timeout, 3_600, "timeout must be sent in seconds, clamped to 1 hour")
        XCTAssertEqual(DirectE2BClient.maxSandboxTimeoutMs, 3_600_000)
        XCTAssertEqual(DirectE2BClient.maxSandboxTimeoutSeconds, 3_600)
    }

    /// Negative or zero timeouts shouldn't blow up — clamp to 0
    /// (e2b.dev itself enforces the lower bound).
    func testCreateSandboxClampsNegativeTimeoutToZero() async throws {
        final class CapturingHTTP: HTTPClient, @unchecked Sendable {
            var capturedBody: Data?
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                capturedBody = request.httpBody
                return (
                    json(#"{"sandboxID":"sb_abc","clientID":"cli_xyz"}"#),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        }
        let cap = CapturingHTTP()
        let client = DirectE2BClient(
            apiKey: "e2b_testkey1234567890abcdef",
            http: cap
        )
        _ = try await client.createSandbox(timeoutMs: -1)
        let body = try XCTUnwrap(cap.capturedBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let timeout = try XCTUnwrap(obj["timeout"] as? Int)
        XCTAssertEqual(timeout, 0)
    }

    // MARK: - killSandbox

    func testKillSandboxSendsDelete() async throws {
        // Use a capturing HTTP client to assert the request shape.
        final class Capturing: HTTPClient, @unchecked Sendable {
            var lastMethod: String?
            var lastURL: String?
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                lastMethod = request.httpMethod
                lastURL = request.url?.absoluteString
                return (Data(), HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }
        }
        let cap = Capturing()
        let client = DirectE2BClient(
            apiKey: "e2b_testkey1234567890abcdef",
            http: cap
        )
        await client.killSandbox(sandboxId: "sb_xyz")
        XCTAssertEqual(cap.lastMethod, "DELETE")
        XCTAssertEqual(cap.lastURL?.contains("/sandboxes/sb_xyz"), true)
    }

    func testKillSandboxWithoutKeyIsNoop() async {
        // No HTTP client needed — empty key short-circuits.
        let client = DirectE2BClient(apiKey: "   ", http: MockHTTPClient(routes: []))
        await client.killSandbox(sandboxId: "sb_xyz") // should not throw
    }

    // MARK: - extendTimeout

    func testExtendTimeoutPostsSecondsToTimeoutEndpoint() async throws {
        final class Capturing: HTTPClient, @unchecked Sendable {
            var lastMethod: String?
            var lastURL: String?
            var capturedBody: Data?
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                lastMethod = request.httpMethod
                lastURL = request.url?.absoluteString
                capturedBody = request.httpBody
                return (Data(), HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }
        }
        let cap = Capturing()
        let client = DirectE2BClient(
            apiKey: "e2b_testkey1234567890abcdef",
            http: cap
        )
        let status = try await client.extendTimeout(sandboxId: "sb_xyz")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(cap.lastMethod, "POST")
        XCTAssertEqual(cap.lastURL?.contains("/sandboxes/sb_xyz/timeout"), true)
        let obj = try XCTUnwrap(
            cap.capturedBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        )
        // e2b's endpoint counts TTL in seconds — the wire value must
        // never be the ms number (same trap as createSandbox).
        XCTAssertEqual(obj["timeout"] as? Int, 3600)
    }

    func testExtendTimeoutClampsToMax() async throws {
        final class Capturing: HTTPClient, @unchecked Sendable {
            var capturedBody: Data?
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                capturedBody = request.httpBody
                return (Data(), HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }
        }
        let cap = Capturing()
        let client = DirectE2BClient(
            apiKey: "e2b_testkey1234567890abcdef",
            http: cap
        )
        // Ask for 2 hours — must clamp down to 1 hour, in seconds.
        try await client.extendTimeout(sandboxId: "sb_xyz", timeoutSeconds: 7_200)
        let obj = try XCTUnwrap(
            cap.capturedBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        )
        XCTAssertEqual(obj["timeout"] as? Int, 3_600)
    }

    // MARK: - verifyKey

    func testVerifyKeySucceedsOn200() async throws {
        let http = MockHTTPClient(routes: [(
            match: "/sandboxes?limit=1",
            status: 200,
            body: json("[]")
        )])
        let client = DirectE2BClient(
            apiKey: "e2b_testkey1234567890abcdef",
            http: http
        )
        let status = try await client.verifyKey()
        XCTAssertEqual(status, 200)
    }

    func testVerifyKeyThrowsOn401() async {
        let http = MockHTTPClient(routes: [(
            match: "/sandboxes?limit=1",
            status: 401,
            body: json(#"{"message":"invalid key"}"#)
        )])
        let client = DirectE2BClient(
            apiKey: "e2b_badkey1234567890abcdef",
            http: http
        )
        do {
            _ = try await client.verifyKey()
            XCTFail("Expected http error")
        } catch let DirectE2BError.http(status, body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("invalid key"))
        } catch {
            XCTFail("Expected http error, got \(error)")
        }
    }

    func testVerifyKeyThrowsOnEmptyKey() async {
        let client = DirectE2BClient(apiKey: "", http: MockHTTPClient(routes: []))
        do {
            _ = try await client.verifyKey()
            XCTFail("Expected noApiKey")
        } catch DirectE2BError.noApiKey {
            // expected
        } catch {
            XCTFail("Expected noApiKey, got \(error)")
        }
    }

    // MARK: - E2bPhoneRepoSelection

    func testRepoSelectionDisplayName() {
        XCTAssertEqual(E2bPhoneRepoSelection.github(fullName: "owner/repo").displayName(), "owner/repo")
        XCTAssertEqual(
            E2bPhoneRepoSelection.url("https://example.com/x.git").displayName(),
            "https://example.com/x.git"
        )
    }
}
