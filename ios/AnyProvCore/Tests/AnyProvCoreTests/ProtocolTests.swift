import XCTest
@testable import AnyProvCore

final class ProtocolTests: XCTestCase {
    func testCreateSessionEncodesExpectedShape() throws {
        let msg = ClientMessage.createSession(
            sessionId: "s1",
            repo: RepoRef(fullName: "owner/repo", workBranch: "apc/work"),
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
        XCTAssertEqual(repo["workBranch"] as? String, "apc/work")
        let model = obj["model"] as! [String: Any]
        XCTAssertEqual(model["provider"] as? String, "anthropic")
    }

    func testUserMessageEncoding() throws {
        let data = try JSONEncoder().encode(ClientMessage.userMessage(sessionId: "s1", text: "hello"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "user_message")
        XCTAssertEqual(obj["text"] as? String, "hello")
    }

    func testCreateSessionEncodesFullMCPServers() throws {
        let mcp = MCPServerConfig(
            id: "fs",
            name: "filesystem",
            description: "Local FS",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem"],
            env: ["HOME": "/tmp"],
            isEnabled: true)
        let msg = ClientMessage.createSession(
            sessionId: "s1",
            repo: RepoRef(fullName: "owner/repo", workBranch: "apc/work"),
            environment: nil,
            model: ModelSelection(provider: .anthropic, model: "claude-sonnet-4", apiKey: "k"),
            permissionMode: .acceptEdits,
            skills: [],
            mcpServers: [mcp])
        let data = try JSONEncoder().encode(msg)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let servers = obj["mcpServers"] as! [[String: Any]]
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0]["id"] as? String, "fs")
        XCTAssertEqual(servers[0]["name"] as? String, "filesystem")
        XCTAssertEqual(servers[0]["description"] as? String, "Local FS")
        XCTAssertEqual(servers[0]["command"] as? String, "npx")
        XCTAssertEqual(servers[0]["isEnabled"] as? Bool, true)
        XCTAssertNotNil(servers[0]["args"])
        XCTAssertNotNil(servers[0]["env"])
    }

    func testGitPublishEncoding() throws {
        let data = try JSONEncoder().encode(ClientMessage.gitPublish(
            sessionId: "s1",
            message: "feat: add notes",
            commit: true,
            push: true,
            openPr: false))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "git_publish")
        XCTAssertEqual(obj["sessionId"] as? String, "s1")
        XCTAssertEqual(obj["message"] as? String, "feat: add notes")
        XCTAssertEqual(obj["commit"] as? Bool, true)
        XCTAssertEqual(obj["push"] as? Bool, true)
        XCTAssertEqual(obj["openPr"] as? Bool, false)
    }

    func testDecodeGitResult() throws {
        let msg = try JSONDecoder().decode(ServerMessage.self, from: json(
            #"{"type":"git_result","sessionId":"s1","action":"commit+push","ok":true,"detail":"Pushed.","url":"https://github.com/o/r/compare/main...b"}"#))
        guard case let .gitResult(sessionId, action, ok, detail, url) = msg else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(action, "commit+push")
        XCTAssertTrue(ok)
        XCTAssertEqual(detail, "Pushed.")
        XCTAssertEqual(url, "https://github.com/o/r/compare/main...b")
    }

    func testTunnelStartEncoding() throws {
        let data = try JSONEncoder().encode(ClientMessage.tunnelStart(
            sessionId: "s1", port: 3000, provider: "cloudflare"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "tunnel_start")
        XCTAssertEqual(obj["port"] as? Int, 3000)
        XCTAssertEqual(obj["provider"] as? String, "cloudflare")
    }

    func testDecodeFileListWithChanges() throws {
        let msg = try JSONDecoder().decode(ServerMessage.self, from: json(
            #"{"type":"file_list_result","sessionId":"s1","path":"","entries":[{"name":"a.ts","path":"a.ts","isDirectory":false,"size":12,"modifiedAt":"2020-01-01T00:00:00.000Z","changeStatus":"M"}],"diff":" a.ts | 1 +\n","changes":[{"path":"a.ts","status":"M"}]}"#))
        guard case let .fileListResult(_, path, entries, diff, changes) = msg else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(path, "")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].changeStatus, "M")
        XCTAssertEqual(diff, " a.ts | 1 +\n")
        XCTAssertEqual(changes?.first?.path, "a.ts")
    }

    func testDecodeTunnelStatus() throws {
        let msg = try JSONDecoder().decode(ServerMessage.self, from: json(
            #"{"type":"tunnel_status","sessionId":"s1","tunnels":[{"id":"t1","port":3000,"provider":"localtunnel","status":"up","url":"https://x.loca.lt"}],"availableProviders":["localtunnel","cloudflare"]}"#))
        guard case let .tunnelStatus(_, tunnels, providers) = msg else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(tunnels.count, 1)
        XCTAssertEqual(tunnels[0].url, "https://x.loca.lt")
        XCTAssertEqual(providers, ["localtunnel", "cloudflare"])
    }

    func testDecodeServerMessages() throws {
        let decoder = JSONDecoder()

        let created = try decoder.decode(ServerMessage.self, from: json(
            #"{"type":"session_created","sessionId":"s1","workdir":"/tmp/x","baseBranch":"main","workBranch":"apc/work"}"#))
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
