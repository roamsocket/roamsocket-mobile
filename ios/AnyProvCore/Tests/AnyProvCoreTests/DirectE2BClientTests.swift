import XCTest
@testable import AnyProvCore

final class DirectE2BClientTests: XCTestCase {
    // MARK: - Connect envelope

    func testConnectEnvelopeWrapsLengthBigEndian() {
        let body = Data("hello".utf8)
        let wrapped = ConnectEnvelope.wrap(body)
        // Flags byte is 0 (uncompressed, not end-of-stream).
        XCTAssertEqual(wrapped[0], 0)
        // Length is 5 in big-endian: [0, 0, 0, 5].
        XCTAssertEqual(wrapped[1], 0)
        XCTAssertEqual(wrapped[2], 0)
        XCTAssertEqual(wrapped[3], 0)
        XCTAssertEqual(wrapped[4], 5)
        XCTAssertEqual(wrapped.dropFirst(5), body)
    }

    func testConnectEnvelopeHandlesEmptyPayload() {
        let wrapped = ConnectEnvelope.wrap(Data())
        XCTAssertEqual(wrapped.count, 5)
        XCTAssertEqual(wrapped[0], 0)
        // Length zero in big-endian: [0, 0, 0, 0].
        XCTAssertEqual(Array(wrapped[1...4]), [0, 0, 0, 0])
    }

    func testConnectEnvelopeHandlesLargePayload() {
        // 200_000 bytes exercises the 3-byte length boundary.
        let body = Data(repeating: 0x41, count: 200_000)
        let wrapped = ConnectEnvelope.wrap(body)
        XCTAssertEqual(wrapped.count, 5 + body.count)
        let length = wrapped[1...4].reduce(into: UInt32(0)) { acc, byte in
            acc = (acc << 8) | UInt32(byte)
        }
        XCTAssertEqual(length, UInt32(body.count))
    }

    func testConnectEnvelopeRoundTripsBytes() {
        let original = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x10])
        let wrapped = ConnectEnvelope.wrap(original)
        XCTAssertEqual(Array(wrapped.dropFirst(5)), Array(original))
    }

    // MARK: - Shell script

    func testShellScriptUsesBashSetEForEarlyExit() {
        let script = DirectE2BClient.buildShellScript(
            repo: .github(fullName: "owner/repo"),
            branch: "main",
            command: "echo hi",
            githubToken: nil,
        )
        XCTAssertTrue(script.contains("set -e"))
        XCTAssertTrue(script.contains("rm -rf /code"))
        XCTAssertTrue(script.contains("git clone --depth 1"))
        XCTAssertTrue(script.contains("https://github.com/owner/repo.git"))
        XCTAssertTrue(script.contains("git fetch --depth 1 origin"))
        XCTAssertTrue(script.contains("git checkout"))
        XCTAssertTrue(script.hasSuffix("echo hi"))
    }

    func testShellScriptInjectsTokenForPrivateRepo() {
        let script = DirectE2BClient.buildShellScript(
            repo: .github(fullName: "owner/private"),
            branch: "main",
            command: "make test",
            githubToken: "ghp_secret",
        )
        XCTAssertTrue(script.contains("https://oauth2:ghp_secret@github.com/owner/private.git"))
    }

    func testShellScriptQuotesBranchAndCommand() {
        // Branch and command can contain shell metacharacters; the
        // shell-quote helper must isolate them.
        let script = DirectE2BClient.buildShellScript(
            repo: .url("https://example.com/repo.git"),
            branch: "feat/with space",
            command: "echo $HOME && rm -rf /",
            githubToken: nil,
        )
        // The space-bearing branch must be quoted — bare `git checkout feat/with space`
        // would split on whitespace.
        XCTAssertTrue(script.contains("'feat/with space'"))
        // The user command is appended verbatim after the clone +
        // checkout steps, so the user owns its quoting. We just want
        // to confirm it shows up unaltered (no extra escaping).
        XCTAssertTrue(script.hasSuffix("echo $HOME && rm -rf /"))
    }

    func testShellScriptSkipsTokenInjectionForEmptyToken() {
        let script = DirectE2BClient.buildShellScript(
            repo: .github(fullName: "owner/repo"),
            branch: "main",
            command: "true",
            githubToken: "",
        )
        XCTAssertFalse(script.contains("oauth2:"))
        XCTAssertTrue(script.contains("https://github.com/owner/repo.git"))
    }

    // MARK: - Shell quoting

    func testShellQuoteReturnsEmptyAsDoubleQuotedEmpty() {
        XCTAssertEqual(ShellQuote.escape(""), "''")
    }

    func testShellQuotePassesSafeChars() {
        XCTAssertEqual(ShellQuote.escape("main"), "main")
        XCTAssertEqual(ShellQuote.escape("feat/foo"), "feat/foo")
        XCTAssertEqual(ShellQuote.escape("v1.2.3-rc"), "v1.2.3-rc")
    }

    func testShellQuoteWrapsUnsafeChars() {
        XCTAssertEqual(ShellQuote.escape("with space"), "'with space'")
        XCTAssertEqual(ShellQuote.escape("a;b"), "'a;b'")
    }

    func testShellQuoteEscapesEmbeddedSingleQuote() {
        // shlex-style: close, escape, reopen.
        XCTAssertEqual(ShellQuote.escape("it's"), "'it'\"'\"'s'")
    }
}
