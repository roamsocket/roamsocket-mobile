import XCTest
@testable import AnyProvCore

/// Cross-platform parity runner (iOS side).
///
/// Loads shared JSON fixtures from `docs/parity/` at the repo root and
/// asserts AnyProvCore produces the exact expected results. The Android
/// runner (`android/RoamSocketCore/src/test/.../ParityTest.kt`) loads the
/// same files, so a behavior change on one platform that diverges from the
/// other fails here or there.
///
/// See `docs/parity/README.md` for the fixture format.
final class ParityTests: XCTestCase {

    // MARK: - Fixture loading

    /// Repo root relative to the package: AnyProvCore is at `<root>/ios/AnyProvCore`.
    private static func parityDir() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // Tests/AnyProvCoreTests/… → repo root
        return url.appendingPathComponent("docs/parity")
    }

    private static func loadFixture(_ name: String) throws -> [String: Any] {
        let url = parityDir().appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "parity", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture not an object: \(name)"])
        }
        return obj
    }

    private static func cases(_ fixture: [String: Any]) throws -> [[String: Any]] {
        guard let cases = fixture["cases"] as? [[String: Any]] else {
            throw NSError(domain: "parity", code: 2, userInfo: [NSLocalizedDescriptionKey: "fixture missing cases"])
        }
        return cases
    }

    private static func fail(_ op: String, _ name: String?, _ reason: String) -> Error {
        NSError(domain: "parity", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "[\(op)] case \(name ?? "?"): \(reason)",
        ])
    }

    // MARK: - JSON helpers (normalized comparison)

    /// Canonical JSON encoding that tolerates NSNull leaves (which
    /// JSONSerialization rejects at the top level or inside containers).
    private static func jsonValue(_ any: Any) throws -> Data {
        if let null = any as? NSObject, null === NSNull() {
            return Data("null".utf8)
        }
        if let dict = any as? [String: Any] {
            var parts: [String] = []
            for key in dict.keys.sorted() {
                let encoded = String(data: try jsonValue(dict[key] ?? NSNull()), encoding: .utf8) ?? "null"
                let keyData = try JSONSerialization.data(withJSONObject: [key: 1], options: [.sortedKeys])
                // Extract the quoted key from {"key":1} to get proper escaping.
                let quoted = String(data: keyData, encoding: .utf8)!.dropFirst().dropLast()
                let keyPart = quoted.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "\"\(key)\""
                parts.append("\(keyPart):\(encoded)")
            }
            return Data(("{" + parts.joined(separator: ",") + "}").utf8)
        }
        if let array = any as? [Any] {
            var parts: [String] = []
            for item in array {
                parts.append(String(data: try jsonValue(item), encoding: .utf8) ?? "null")
            }
            return Data(("[" + parts.joined(separator: ",") + "]").utf8)
        }
        if let number = any as? NSNumber {
            return Data(number.stringValue.utf8)
        }
        if let bool = any as? Bool {
            return Data((bool ? "true" : "false").utf8)
        }
        if let string = any as? String {
            let quoted = try JSONSerialization.data(withJSONObject: [string], options: [])
            // ["value"] -> "value": strip the array brackets.
            let text = String(data: quoted, encoding: .utf8)!
            return Data(text.dropFirst().dropLast().utf8)
        }
        throw fail("json", nil, "unsupported JSON value type \(type(of: any))")
    }

    private static func assertEqualNormalized(_ expected: Any, _ actual: Any, op: String, name: String?) throws {
        let a = try jsonValue(expected)
        let b = try jsonValue(actual)
        if a != b {
            let expectedText = String(data: a, encoding: .utf8) ?? "?"
            let actualText = String(data: b, encoding: .utf8) ?? "?"
            XCTFail("[\(op)] case \(name ?? "?") mismatch\n expected: \(expectedText)\n   actual: \(actualText)")
            throw fail(op, name, "mismatch (see failure above)")
        }
    }

    // MARK: - decode_server_message

    func testDecodeServerMessageParity() throws {
        let fixture = try Self.loadFixture("protocol-cases.json")
        let op = fixture["op"] as? String ?? "?"
        for caseDict in try Self.cases(fixture) {
            let name = caseDict["name"] as? String
            let input = (caseDict["input"] as? String) ?? ""
            let expected = try XCTUnwrap(caseDict["expected"] as? [String: Any], "case \(name ?? "?") missing expected")

            do {
                let msg = try JSONDecoder().decode(ServerMessage.self, from: Data(input.utf8))
                let actual = Self.normalize(serverMessage: msg)
                try Self.assertEqualNormalized(expected, actual, op: op, name: name)
            } catch let error as DecodingError {
                // Unknown discriminator and malformed payloads must fail decode
                // on every platform; expectation is `kind == "error"`.
                let actual: [String: Any] = ["kind": "error"]
                try Self.assertEqualNormalized(expected, actual, op: op, name: name)
                _ = error
            }
        }
    }

    /// Map a decoded ServerMessage into the normalized JSON form shared by
    /// both runners. Keep this mapping boring and explicit.
    private static func normalize(serverMessage msg: ServerMessage) -> [String: Any] {
        switch msg {
        case let .sessionCreated(sessionId, workdir, baseBranch, workBranch):
            return ["kind": "session_created", "sessionId": sessionId, "workdir": workdir,
                    "baseBranch": baseBranch, "workBranch": workBranch]
        case let .assistantDelta(sessionId, text):
            return ["kind": "assistant_delta", "sessionId": sessionId, "text": text]
        case let .toolCall(sessionId, callId, tool, summary):
            return ["kind": "tool_call", "sessionId": sessionId, "callId": callId,
                    "tool": tool, "summary": summary]
        case let .toolResult(sessionId, callId, ok, output):
            return ["kind": "tool_result", "sessionId": sessionId, "callId": callId,
                    "ok": ok, "output": output]
        case let .diff(sessionId, path, patch, added, removed):
            return ["kind": "diff", "sessionId": sessionId, "path": path, "patch": patch,
                    "added": added, "removed": removed]
        case let .permissionRequest(sessionId, requestId, tool, summary):
            return ["kind": "permission_request", "sessionId": sessionId, "requestId": requestId,
                    "tool": tool, "summary": summary]
        case let .sessionDone(sessionId, stopReason):
            return ["kind": "session_done", "sessionId": sessionId, "stopReason": stopReason as Any? ?? NSNull()]
        case let .prCreated(sessionId, url):
            return ["kind": "pr_created", "sessionId": sessionId, "url": url]
        case let .gitResult(sessionId, action, ok, detail, url):
            return ["kind": "git_result", "sessionId": sessionId, "action": action, "ok": ok,
                    "detail": detail, "url": url as Any? ?? NSNull()]
        case let .error(sessionId, message):
            return ["kind": "error", "sessionId": sessionId as Any? ?? NSNull(), "message": message]
        case let .fileWriteResult(sessionId, path, ok, message):
            return ["kind": "file_write_result", "sessionId": sessionId, "path": path, "ok": ok,
                    "message": message as Any? ?? NSNull()]
        case let .fileListResult(sessionId, path, entries, diff, changes):
            return ["kind": "file_list_result", "sessionId": sessionId, "path": path,
                    "entries": entries.map(Self.normalize(fileEntry:)),
                    "diff": diff as Any? ?? NSNull(),
                    "changes": (changes ?? []).map(Self.normalize(fileChange:))]
        case let .portListResult(sessionId, ports):
            return ["kind": "port_list_result", "sessionId": sessionId,
                    "ports": ports.map { ["port": $0.port, "pid": $0.pid, "command": $0.command] }]
        case let .tunnelStatus(sessionId, tunnels, providers):
            return ["kind": "tunnel_status", "sessionId": sessionId,
                    "tunnels": tunnels.map(Self.normalize(tunnel:)),
                    "availableProviders": providers]
        case let .remoteEndpoint(status, url, provider, error):
            return ["kind": "remote_endpoint", "status": status, "url": url as Any? ?? NSNull(),
                    "provider": provider as Any? ?? NSNull(), "error": error as Any? ?? NSNull()]
        case let .taskList(sessionId, tasks):
            return ["kind": "task_list", "sessionId": sessionId,
                    "tasks": tasks.map { ["id": $0.id, "content": $0.content, "status": $0.status] }]
        case let .goalStatus(sessionId, status, condition, reason, turns, started, elapsed, message):
            return ["kind": "goal_status", "sessionId": sessionId, "status": status,
                    "condition": condition as Any? ?? NSNull(), "reason": reason as Any? ?? NSNull(),
                    "turnsEvaluated": turns as Any? ?? NSNull(),
                    "startedAt": started as Any? ?? NSNull(),
                    "elapsedMs": elapsed as Any? ?? NSNull(), "message": message]
        case let .modelStatus(sessionId, status, hubID, message):
            return ["kind": "model_status", "sessionId": sessionId, "status": status,
                    "hubID": hubID as Any? ?? NSNull(), "message": message as Any? ?? NSNull()]
        case let .transcriptReplay(sessionId, events, truncated, isLive):
            return ["kind": "transcript_replay", "sessionId": sessionId,
                    "truncated": truncated, "isLive": isLive,
                    "events": events.map(Self.normalize(transcriptEvent:))]
        case let .e2bList(sessionId, runs):
            return ["kind": "e2b_list", "sessionId": sessionId as Any? ?? NSNull(),
                    "runs": runs.map(Self.normalize(e2bRun:))]
        case let .e2bKeyAck(overrideActive):
            return ["kind": "e2b_key_ack", "overrideActive": overrideActive]
        default:
            return ["kind": "unhandled_parity_case"]
        }
    }

    private static func normalize(fileEntry e: ServerMessage.FileEntryPayload) -> [String: Any] {
        var out: [String: Any] = [
            "name": e.name, "path": e.path, "isDirectory": e.isDirectory,
            "size": e.size, "modifiedAt": e.modifiedAt,
        ]
        out["changeStatus"] = e.changeStatus as Any? ?? NSNull()
        return out
    }

    private static func normalize(fileChange c: ServerMessage.FileChangePayload) -> [String: Any] {
        ["path": c.path, "status": c.status]
    }

    private static func normalize(tunnel t: ServerMessage.TunnelPayload) -> [String: Any] {
        ["id": t.id, "port": t.port, "provider": t.provider, "status": t.status,
         "url": t.url ?? NSNull()]
    }

    private static func normalize(e2bRun r: E2bRunPayload) -> [String: Any] {
        [
            "id": r.id, "sessionId": r.sessionId, "repoFullName": r.repoFullName,
            "branch": r.branch, "command": r.command, "status": r.status,
            "exitCode": r.exitCode as Any? ?? NSNull(),
            "sandboxId": r.sandboxId as Any? ?? NSNull(),
            "sandboxUrl": r.sandboxUrl as Any? ?? NSNull(),
            "startedAt": r.startedAt as Any? ?? NSNull(),
            "finishedAt": r.finishedAt as Any? ?? NSNull(),
            "outputTail": r.outputTail,
            "error": r.error as Any? ?? NSNull(),
        ]
    }

    private static func normalize(transcriptEvent e: ServerMessage.TranscriptEvent) -> [String: Any] {
        switch e {
        case let .user(ts, text):
            return ["kind": "user", "ts": ts, "text": text]
        case let .assistantDelta(sessionId, text):
            return ["kind": "assistant_delta", "sessionId": sessionId, "text": text]
        case let .toolCall(sessionId, callId, tool, summary):
            return ["kind": "tool_call", "sessionId": sessionId, "callId": callId,
                    "tool": tool, "summary": summary]
        case let .toolResult(sessionId, callId, ok, output):
            return ["kind": "tool_result", "sessionId": sessionId, "callId": callId,
                    "ok": ok, "output": output]
        case let .diff(sessionId, path, patch, added, removed):
            return ["kind": "diff", "sessionId": sessionId, "path": path, "patch": patch,
                    "added": added, "removed": removed]
        }
    }

    // MARK: - encode_client_message

    func testEncodeClientMessageParity() throws {
        let fixture = try Self.loadFixture("protocol-encode-cases.json")
        let op = fixture["op"] as? String ?? "?"
        for caseDict in try Self.cases(fixture) {
            let name = caseDict["name"] as? String
            let input = try XCTUnwrap(caseDict["input"] as? [String: Any], "case \(name ?? "?") missing input")
            let expected = try XCTUnwrap(caseDict["expected"] as? [String: Any], "case \(name ?? "?") missing expected")

            let msg = try Self.clientMessage(from: input)
            let data = try JSONEncoder().encode(msg)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

            // Subset compare: expected keys must be present with exact values;
            // extra keys the platform omits (e.g. default suppression) fail.
            for (key, want) in expected {
                guard let got = obj[key] else {
                    XCTFail("[\(op)] case \(name ?? "?") missing key \(key)")
                    continue
                }
                try Self.assertEqualNormalized(want, got, op: op, name: name)
            }
        }
    }

    private static func clientMessage(from input: [String: Any]) throws -> ClientMessage {
        let caseName = try XCTUnwrap(input["case"] as? String)
        let string = { (key: String) in input[key] as? String }
        let int = { (key: String) in input[key] as? Int }
        let bool = { (key: String) in input[key] as? Bool }

        func modelSelection(_ dict: [String: Any]?) -> ModelSelection? {
            guard let dict else { return nil }
            return ModelSelection(
                provider: ProviderID(rawValue: dict["provider"] as? String ?? "") ?? .anthropic,
                model: dict["model"] as? String ?? "",
                effort: Effort(rawValue: dict["effort"] as? String ?? "high") ?? .high,
                apiKey: dict["apiKey"] as? String ?? "")
        }

        switch caseName {
        case "user_message":
            return .userMessage(sessionId: string("sessionId") ?? "", text: string("text") ?? "",
                                model: modelSelection(input["model"] as? [String: Any]))
        case "interrupt":
            return .interrupt(sessionId: string("sessionId") ?? "")
        case "skills_sync_request":
            return .skillsSyncRequest
        case "git_publish":
            return .gitPublish(sessionId: string("sessionId") ?? "", message: string("message") ?? "",
                               commit: bool("commit") ?? false, push: bool("push") ?? false,
                               openPr: bool("openPr") ?? false)
        case "file_write":
            return .fileWrite(sessionId: string("sessionId") ?? "", path: string("path") ?? "",
                              content: string("content") ?? "")
        case "tunnel_start":
            return .tunnelStart(sessionId: string("sessionId") ?? "", port: int("port") ?? 0,
                                provider: string("provider") ?? "")
        case "remote_endpoint_request":
            return .remoteEndpointRequest(force: bool("force") ?? false)
        case "create_session":
            let repoDict = try XCTUnwrap(input["repo"] as? [String: Any])
            let repo = RepoRef(fullName: repoDict["fullName"] as? String ?? "",
                               workBranch: repoDict["workBranch"] as? String ?? "")
            var environment: EnvironmentConfig?
            if let envDict = input["environment"] as? [String: Any] {
                environment = EnvironmentConfig(
                    name: envDict["name"] as? String ?? "",
                    variables: envDict["variables"] as? [String: String] ?? [:])
            }
            var servers: [MCPServerConfig] = []
            if let serverDicts = input["mcpServers"] as? [[String: Any]] {
                servers = serverDicts.map { d in
                    MCPServerConfig(
                        id: d["id"] as? String ?? "",
                        name: d["name"] as? String ?? "",
                        description: d["description"] as? String ?? "",
                        command: d["command"] as? String ?? "",
                        args: d["args"] as? [String] ?? [],
                        env: d["env"] as? [String: String] ?? [:],
                        isEnabled: d["isEnabled"] as? Bool ?? true)
                }
            }
            return .createSession(
                sessionId: string("sessionId"),
                repo: repo,
                environment: environment,
                model: try XCTUnwrap(modelSelection(input["model"] as? [String: Any])),
                permissionMode: PermissionMode(rawValue: string("permissionMode") ?? "") ?? .acceptEdits,
                skills: input["skills"] as? [String] ?? [],
                mcpServers: servers)
        default:
            throw fail("encode_client_message", caseName, "runner does not implement case")
        }
    }

    // MARK: - parse_env

    func testParseEnvParity() throws {
        let fixture = try Self.loadFixture("env-cases.json")
        let op = fixture["op"] as? String ?? "?"
        for caseDict in try Self.cases(fixture) {
            let name = caseDict["name"] as? String
            let input = (caseDict["input"] as? String) ?? ""
            let expected = try XCTUnwrap(caseDict["expected"] as? [String: Any])
            let vars = try XCTUnwrap(expected["vars"] as? [String: String])

            let parsed = EnvironmentConfig.parseEnv(input)
            try Self.assertEqualNormalized(vars, parsed, op: op, name: name)
        }
    }

    // MARK: - prettify_display_name

    func testPrettifyDisplayNameParity() throws {
        let fixture = try Self.loadFixture("model-cases.json")
        let op = fixture["op"] as? String ?? "?"
        for caseDict in try Self.cases(fixture) {
            let name = caseDict["name"] as? String
            let input = (caseDict["input"] as? String) ?? ""
            let expected = try XCTUnwrap(caseDict["expected"] as? [String: Any])
            let want = try XCTUnwrap(expected["name"] as? String)

            let got = AIModel.prettifiedDisplayName(for: input)
            if got != want {
                XCTFail("[\(op)] case \(name ?? "?"): expected \"\(want)\", got \"\(got)\"")
            }
        }
    }
}
