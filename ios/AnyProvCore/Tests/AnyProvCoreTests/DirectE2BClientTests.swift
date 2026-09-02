import XCTest
@testable import AnyProvCore

final class DirectE2BClientTests: XCTestCase {
    // MARK: - PythonQuote

    func testPythonQuoteLeavesSafeStringsAlone() {
        XCTAssertEqual(PythonQuote.escape("hello"), "hello")
        XCTAssertEqual(PythonQuote.escape("/usr/local/bin"), "/usr/local/bin")
        // No spaces, no special chars → passed through unchanged.
        XCTAssertEqual(PythonQuote.escape("npm-test"), "npm-test")
        XCTAssertEqual(PythonQuote.escape("v1.2.3"), "v1.2.3")
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
