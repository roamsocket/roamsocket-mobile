import XCTest
@testable import MobileAICore

final class ProtocolTests: XCTestCase {
    func testCreateSessionEncodesExpectedShape() throws {
        let msg = ClientMessage.createSession(
            sessionId: "s1",
            repo: RepoRef(fullName: "owner/repo", workBranch: "cmai/work"),
            environment: EnvironmentConfig(name: "kind", variables: ["API_KEY": "hunter2"]),
            model: ModelSelection(provider: .anthropic, model: "claude-sonnet-4", apiKey: "k"),
            permissionMode: .acceptEdits)
        let data = try JSONEncoder().encode(msg)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "create_session")
        XCTAssertEqual(obj["sessionId"] as? String, "s1")
        XCTAssertEqual(obj["permissionMode"] as? String, "acceptEdits")
        let repo = obj["repo"] as! [String: Any]
        XCTAssertEqual(repo["fullName"] as? String, "owner/repo")
        XCTAssertEqual(repo["workBranch"] as? String, "cmai/work")
        let model = obj["model"] as! [String: Any]
        XCTAssertEqual(model["provider"] as? String, "anthropic")
    }

    func testUserMessageEncoding() throws {
        let data = try JSONEncoder().encode(ClientMessage.userMessage(sessionId: "s1", text: "hello"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "user_message")
        XCTAssertEqual(obj["text"] as? String, "hello")
    }

    func testDecodeServerMessages() throws {
        let decoder = JSONDecoder()

        let created = try decoder.decode(ServerMessage.self, from: json(
            #"{"type":"session_created","sessionId":"s1","workdir":"/tmp/x","baseBranch":"main","workBranch":"cmai/work"}"#))
        guard case let .sessionCreated(sessionId, _, baseBranch, _) = created else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(baseBranch, "main")

        let toolCall = try decoder.decode(ServerMessage.self, from: json(
            #"{"type":"tool_call","sessionId":"s1","callId":"c1","tool":"bash","summary":"bash: ls"}"#))
        guard case let .toolCall(_, callId, tool, summary) = toolCall else { return XCTFail("wrong case") }
        XCTAssertEqual(callId, "c1")
        XCTAssertEqual(tool, "bash")
        XCTAssertEqual(summary, "bash: ls")

        let diff = try decoder.decode(ServerMessage.self, from: json(
            #"{"type":"diff","sessionId":"s1","path":"a.txt","patch":"@@","added":3,"removed":1}"#))
        guard case let .diff(_, path, _, added, removed) = diff else { return XCTFail("wrong case") }
        XCTAssertEqual(path, "a.txt")
        XCTAssertEqual(added, 3)
        XCTAssertEqual(removed, 1)

        let done = try decoder.decode(ServerMessage.self, from: json(
            #"{"type":"session_done","sessionId":"s1"}"#))
        guard case let .sessionDone(_, stopReason) = done else { return XCTFail("wrong case") }
        XCTAssertNil(stopReason)

        let err = try decoder.decode(ServerMessage.self, from: json(
            #"{"type":"error","message":"boom"}"#))
        guard case let .error(sessionId2, message) = err else { return XCTFail("wrong case") }
        XCTAssertNil(sessionId2)
        XCTAssertEqual(message, "boom")
    }

    func testEnvParsing() {
        let vars = EnvironmentConfig.parseEnv("""
        # a comment
        API_KEY=hunter2
        QUOTED="with spaces"
        EMPTYLINE=

        BAD LINE WITHOUT EQUALS
        """)
        XCTAssertEqual(vars["API_KEY"], "hunter2")
        XCTAssertEqual(vars["QUOTED"], "with spaces")
        XCTAssertEqual(vars["EMPTYLINE"], "")
        XCTAssertNil(vars["BAD LINE WITHOUT EQUALS"])
    }
}
