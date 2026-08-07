import XCTest
@testable import AnyProvCore

final class ProtocolTests: XCTestCase {
    func testEndpointDefaultsCompanionPortForBareIP() throws {
        let endpoint = try XCTUnwrap(ServerClient.Endpoint(host: "192.168.1.20"))
        XCTAssertEqual(endpoint.baseURL.scheme, "http")
        XCTAssertEqual(endpoint.baseURL.host, "192.168.1.20")
        XCTAssertEqual(endpoint.baseURL.port, 4319)
    }

    func testEndpointPreservesExplicitPort() throws {
        let endpoint = try XCTUnwrap(ServerClient.Endpoint(host: "http://10.0.0.5:9999"))
        XCTAssertEqual(endpoint.baseURL.port, 9999)
        XCTAssertEqual(endpoint.baseURL.host, "10.0.0.5")
    }

    func testEndpointRejectsEmptyHost() {
        XCTAssertNil(ServerClient.Endpoint(host: "   "))
        XCTAssertNil(ServerClient.Endpoint(host: "http://"))
    }

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
        XCTAssertNil(obj["model"])
    }

    func testUserMessageEncodingWithModel() throws {
        let model = ModelSelection(
            provider: .anthropic,
            model: "claude-sonnet-4",
            effort: .high,
            apiKey: "sk-test"
        )
        let data = try JSONEncoder().encode(ClientMessage.userMessage(
            sessionId: "s1",
            text: "switch me",
            model: model
        ))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "user_message")
        let m = obj["model"] as! [String: Any]
        XCTAssertEqual(m["provider"] as? String, "anthropic")
        XCTAssertEqual(m["model"] as? String, "claude-sonnet-4")
        XCTAssertEqual(m["apiKey"] as? String, "sk-test")
    }

    func testFileWriteEncoding() throws {
        let data = try JSONEncoder().encode(ClientMessage.fileWrite(
            sessionId: "s1",
            path: "src/App.swift",
            content: "print(1)\n"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "file_write")
        XCTAssertEqual(obj["sessionId"] as? String, "s1")
        XCTAssertEqual(obj["path"] as? String, "src/App.swift")
        XCTAssertEqual(obj["content"] as? String, "print(1)\n")
    }

    func testDecodeFileWriteResult() throws {
        let msg = try JSONDecoder().decode(ServerMessage.self, from: json(
            #"{"type":"file_write_result","sessionId":"s1","path":"a.md","ok":true,"message":"Saved a.md"}"#))
        guard case let .fileWriteResult(sessionId, path, ok, message) = msg else {
            return XCTFail("expected fileWriteResult")
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(path, "a.md")
        XCTAssertTrue(ok)
        XCTAssertEqual(message, "Saved a.md")
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

    func testRemoteEndpointRequestEncoding() throws {
        let forced = try JSONEncoder().encode(ClientMessage.remoteEndpointRequest(force: true))
        let forcedObj = try JSONSerialization.jsonObject(with: forced) as! [String: Any]
        XCTAssertEqual(forcedObj["type"] as? String, "remote_endpoint_request")
        XCTAssertEqual(forcedObj["force"] as? Bool, true)

        let soft = try JSONEncoder().encode(ClientMessage.remoteEndpointRequest(force: false))
        let softObj = try JSONSerialization.jsonObject(with: soft) as! [String: Any]
        XCTAssertEqual(softObj["type"] as? String, "remote_endpoint_request")
        XCTAssertNil(softObj["force"])
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

    func testDecodeRemoteEndpoint() throws {
        let msg = try JSONDecoder().decode(ServerMessage.self, from: json(
            #"{"type":"remote_endpoint","status":"up","url":"https://abc.trycloudflare.com","provider":"cloudflare"}"#))
        guard case let .remoteEndpoint(status, url, provider, err) = msg else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(status, "up")
        XCTAssertEqual(url, "https://abc.trycloudflare.com")
        XCTAssertEqual(provider, "cloudflare")
        XCTAssertNil(err)
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

        let tasks = try decoder.decode(ServerMessage.self, from: json(
            #"{"type":"task_list","sessionId":"s1","tasks":[{"id":"1","content":"Plan","status":"completed"},{"id":"2","content":"Ship","status":"in_progress"}]}"#))
        guard case let .taskList(_, items) = tasks else { return XCTFail("wrong case") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].content, "Plan")
        XCTAssertEqual(items[1].status, "in_progress")
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
