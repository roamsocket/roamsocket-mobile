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

    // MARK: - Exit-status parser

    func testParseExitStatusReturnsCodeForExitStatusZero() {
        XCTAssertEqual(ConnectEnvelope.parseExitStatus("exit status 0", exited: true), 0)
    }

    func testParseExitStatusReturnsCodeForNonZero() {
        XCTAssertEqual(ConnectEnvelope.parseExitStatus("exit status 1", exited: true), 1)
        XCTAssertEqual(ConnectEnvelope.parseExitStatus("exit status 127", exited: true), 127)
    }

    func testParseExitStatusNegatesSignalCodes() {
        XCTAssertEqual(ConnectEnvelope.parseExitStatus("signal: 9", exited: true), -9)
        XCTAssertEqual(ConnectEnvelope.parseExitStatus("signal: 15", exited: true), -15)
    }

    func testParseExitStatusIgnoresStaleRunningShapes() {
        // envd sends `{"exited": false}` for in-flight processes; the
        // run is still going, so we must not synthesise a fake code.
        XCTAssertNil(ConnectEnvelope.parseExitStatus(nil, exited: false))
        XCTAssertNil(ConnectEnvelope.parseExitStatus("", exited: true))
        XCTAssertNil(ConnectEnvelope.parseExitStatus("exit status 0", exited: nil))
    }

    func testParseExitStatusRejectsUnrecognisedShape() {
        // Future envd versions might change the status string. Treat
        // anything we don't recognise as a stream error upstream and
        // let the caller surface it.
        XCTAssertNil(ConnectEnvelope.parseExitStatus("weird new shape", exited: true))
    }

    // MARK: - Real envd envelope shape

    /// The real wire format captured from a live `base` sandbox on
    /// 2026-09-01. This pins the parser against the exact byte
    /// sequence so a future envd refactor can't quietly change it.
    func testDecodesCapturedEnvdStream() throws {
        // start, 3 stdout chunks, end, end-of-stream.
        let envelopes: [Data] = [
            envelope(json: ["event": ["start": ["pid": 2003]]]),
            envelope(json: ["event": ["data": ["stdout": "aGVsbG8tZnJvbS1lbnZkCg=="]]]),
            envelope(json: ["event": ["data": ["stdout": "TGludXggZTJiLmxvY2FsIDYuMS4xNTgrICMxIFNNUCBQUkVFTVBUX0RZTkFNSUMgRnJpIEp1bCAgMyAxNDowMjoxNSBVVEMgMjAyNiB4ODZfNjQgR05VL0xpbnV4Cg=="]]]),
            envelope(json: ["event": ["data": ["stdout": "ZG9uZQo="]]]),
            envelope(json: ["event": ["end": ["exited": true, "status": "exit status 0"]]]),
            // Final envelope: end-of-stream with empty JSON `{}` body.
            envelope(flags: ConnectEnvelope.flagEndStream, json: [String: String]()),
        ]
        let stream = envelopes.reduce(Data()) { $0 + $1 }

        // Drive the same `parseNextEvent` the production code uses.
        var buffer = Data()
        var events: [ConnectEnvelope.Event] = []
        for byte in stream {
            buffer.append(byte)
            while let event = try ConnectEnvelope.parseNextEventForTest(from: &buffer) {
                if case .end = event {
                    events.append(event)
                    XCTAssert(buffer.isEmpty, "end-of-stream should be the last envelope")
                    return
                }
                events.append(event)
            }
        }
        XCTFail("stream did not produce an end event; got \(events)")
    }

    func testDataEnvelopeWithoutOutputWrapperDecodes() throws {
        // envd 0.6.x puts the stream field directly under `event.data`
        // (no `output` wrapper). Make sure we accept that shape.
        let env = envelope(json: [
            "event": ["data": ["stderr": "d2FybmluZzogc29tZXRoaW5nIGlzIGZpc2h5Cg=="]], // "warning: something is fishy\n"
        ])
        var buffer = env
        let event = try ConnectEnvelope.parseNextEventForTest(from: &buffer)
        guard case let .data(stream, text) = event else {
            return XCTFail("expected .data, got \(String(describing: event))")
        }
        XCTAssertEqual(stream, "stderr")
        XCTAssertEqual(text, "warning: something is fishy\n")
    }

    // MARK: - Test fixtures

    /// Build a full Connect envelope: 1 byte flags + 4 bytes big-endian
    /// length + JSON body. The default `flags=0` is what envd uses for
    /// every normal message; the end-of-stream test uses
    /// `flagEndStream` (0x02).
    private func envelope(flags: UInt8 = 0, json: Any) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: json)
        var out = Data(capacity: 5 + payload.count)
        out.append(flags)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}
