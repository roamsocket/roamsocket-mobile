import Foundation

/// Swift mirror of `desktop-server/src/protocol.ts`. Keep these in sync with
/// that file and `docs/protocol.md`.

// MARK: Shared value types

public enum PermissionMode: String, Codable, Sendable, CaseIterable {
    case acceptEdits, plan, ask

    public var displayName: String {
        switch self {
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan"
        case .ask: return "Ask"
        }
    }
}

public enum NetworkAccess: String, Codable, Sendable, CaseIterable {
    case trusted, limited, none

    public var displayName: String {
        switch self {
        case .trusted: return "Trusted network access"
        case .limited: return "Limited network access"
        case .none: return "No network access"
        }
    }
}

public struct EnvironmentConfig: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var networkAccess: NetworkAccess
    public var variables: [String: String]

    public var id: String { name }

    public init(name: String, networkAccess: NetworkAccess = .trusted, variables: [String: String] = [:]) {
        self.name = name
        self.networkAccess = networkAccess
        self.variables = variables
    }

    /// Parse `.env`-format text (as entered in IMG_0990) into variables.
    public static func parseEnv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}

public struct ModelSelection: Codable, Hashable, Sendable {
    public var provider: ProviderID
    public var model: String
    public var effort: Effort
    public var apiKey: String

    public init(provider: ProviderID, model: String, effort: Effort = .high, apiKey: String) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.apiKey = apiKey
    }
}

// MARK: HTTP pairing

public struct PairRequest: Codable, Sendable {
    public var code: String
    public var deviceName: String
    public init(code: String, deviceName: String) {
        self.code = code
        self.deviceName = deviceName
    }
}

public struct PairResponse: Codable, Sendable {
    public let token: String
    public let serverName: String
    public let serverVersion: String
}

// MARK: app -> server

public struct RepoRef: Codable, Sendable {
    public var fullName: String
    public var baseBranch: String?
    public var workBranch: String
    public var githubToken: String?
    public init(fullName: String, baseBranch: String? = nil, workBranch: String, githubToken: String? = nil) {
        self.fullName = fullName
        self.baseBranch = baseBranch
        self.workBranch = workBranch
        self.githubToken = githubToken
    }
}

/// Discriminated messages the app sends. Encoded with a `type` field.
public enum ClientMessage: Encodable, Sendable {
    case createSession(sessionId: String?, repo: RepoRef, environment: EnvironmentConfig?, model: ModelSelection, permissionMode: PermissionMode, skills: [String] = [], mcpServers: [MCPServerConfig] = [])
    case userMessage(sessionId: String, text: String)
    case permissionResponse(sessionId: String, requestId: String, decision: PermissionDecision)
    case interrupt(sessionId: String)
    case createPR(sessionId: String, title: String, body: String)
    case skillsSyncRequest
    case mcpSyncRequest
    case skillUpsert(skill: Skill)
    case skillDelete(id: String)
    case mcpUpsert(server: MCPServer)
    case mcpDelete(id: String)
    case terminalOpen(terminalId: String?, sessionId: String, cols: Int = 80, rows: Int = 24)
    case terminalInput(terminalId: String, data: String)
    case terminalResize(terminalId: String, cols: Int, rows: Int)
    case terminalKill(terminalId: String)
    case fileList(sessionId: String, path: String)
    case fileRead(sessionId: String, path: String)
    case portList(sessionId: String)

    public enum PermissionDecision: String, Codable, Sendable { case allow, deny }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        switch self {
        case let .createSession(sessionId, repo, environment, model, permissionMode, skills, mcpServers):
            try c.encode("create_session", forKey: .init("type"))
            if let sessionId { try c.encode(sessionId, forKey: .init("sessionId")) }
            try c.encode(repo, forKey: .init("repo"))
            if let environment { try c.encode(environment, forKey: .init("environment")) }
            try c.encode(model, forKey: .init("model"))
            try c.encode(permissionMode, forKey: .init("permissionMode"))
            if !skills.isEmpty { try c.encode(skills, forKey: .init("skills")) }
            if !mcpServers.isEmpty { try c.encode(mcpServers, forKey: .init("mcpServers")) }
        case let .userMessage(sessionId, text):
            try c.encode("user_message", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
            try c.encode(text, forKey: .init("text"))
        case let .permissionResponse(sessionId, requestId, decision):
            try c.encode("permission_response", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
            try c.encode(requestId, forKey: .init("requestId"))
            try c.encode(decision, forKey: .init("decision"))
        case let .interrupt(sessionId):
            try c.encode("interrupt", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
        case let .createPR(sessionId, title, body):
            try c.encode("create_pr", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
            try c.encode(title, forKey: .init("title"))
            try c.encode(body, forKey: .init("body"))
        case .skillsSyncRequest:
            try c.encode("skills_sync_request", forKey: .init("type"))
        case .mcpSyncRequest:
            try c.encode("mcp_sync_request", forKey: .init("type"))
        case let .skillUpsert(skill):
            try c.encode("skill_upsert", forKey: .init("type"))
            try c.encode(skill, forKey: .init("skill"))
        case let .skillDelete(id):
            try c.encode("skill_delete", forKey: .init("type"))
            try c.encode(id, forKey: .init("id"))
        case let .mcpUpsert(server):
            try c.encode("mcp_upsert", forKey: .init("type"))
            try c.encode(server, forKey: .init("server"))
        case let .mcpDelete(id):
            try c.encode("mcp_delete", forKey: .init("type"))
            try c.encode(id, forKey: .init("id"))
        case let .terminalOpen(terminalId, sessionId, cols, rows):
            try c.encode("terminal_open", forKey: .init("type"))
            if let terminalId { try c.encode(terminalId, forKey: .init("terminalId")) }
            try c.encode(sessionId, forKey: .init("sessionId"))
            try c.encode(cols, forKey: .init("cols"))
            try c.encode(rows, forKey: .init("rows"))
        case let .terminalInput(terminalId, data):
            try c.encode("terminal_input", forKey: .init("type"))
            try c.encode(terminalId, forKey: .init("terminalId"))
            try c.encode(data, forKey: .init("data"))
        case let .terminalResize(terminalId, cols, rows):
            try c.encode("terminal_resize", forKey: .init("type"))
            try c.encode(terminalId, forKey: .init("terminalId"))
            try c.encode(cols, forKey: .init("cols"))
            try c.encode(rows, forKey: .init("rows"))
        case let .terminalKill(terminalId):
            try c.encode("terminal_kill", forKey: .init("type"))
            try c.encode(terminalId, forKey: .init("terminalId"))
        case let .fileList(sessionId, path):
            try c.encode("file_list", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
            try c.encode(path, forKey: .init("path"))
        case let .fileRead(sessionId, path):
            try c.encode("file_read", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
            try c.encode(path, forKey: .init("path"))
        case let .portList(sessionId):
            try c.encode("port_list", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
        }
    }
}

/// MCP server configuration sent to the desktop server.
public struct MCPServerConfig: Codable, Sendable {
    public let name: String
    public let command: String
    public let args: [String]
    public let env: [String: String]
    
    public init(name: String, command: String, args: [String] = [], env: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }
}

// MARK: server -> app

public enum ServerMessage: Decodable, Sendable {
    case sessionCreated(sessionId: String, workdir: String, baseBranch: String, workBranch: String)
    case assistantDelta(sessionId: String, text: String)
    case toolCall(sessionId: String, callId: String, tool: String, summary: String)
    case toolResult(sessionId: String, callId: String, ok: Bool, output: String)
    case diff(sessionId: String, path: String, patch: String, added: Int, removed: Int)
    case permissionRequest(sessionId: String, requestId: String, tool: String, summary: String)
    case sessionDone(sessionId: String, stopReason: String?)
    case prCreated(sessionId: String, url: String)
    case error(sessionId: String?, message: String)
    case skillsSync(skills: [Skill])
    case mcpSync(servers: [MCPServer])
    case terminalData(terminalId: String, stream: String, data: String)
    case terminalControl(terminalId: String, event: String, code: Int)
    case fileListResult(sessionId: String, path: String, entries: [FileEntryPayload], diff: String?)
    case fileReadResult(sessionId: String, path: String, content: String, truncated: Bool)
    case portListResult(sessionId: String, ports: [PortEntryPayload])

    public struct FileEntryPayload: Codable, Hashable, Sendable {
        public let name: String
        public let path: String
        public let isDirectory: Bool
        public let size: Int
        public let modifiedAt: String
    }
    public struct PortEntryPayload: Codable, Hashable, Sendable {
        public let port: Int
        public let pid: Int
        public let command: String
    }

    private enum K: String, CodingKey {
        case type, sessionId, workdir, baseBranch, workBranch, text, callId, tool
        case summary, ok, output, path, patch, added, removed, requestId, stopReason, url, message
        case skills, servers
        case terminalId, stream, data, event, code
        case entries, diff, content, truncated, ports, port, pid, command
        case name, isDirectory, size, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "session_created":
            self = .sessionCreated(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                workdir: try c.decode(String.self, forKey: .workdir),
                baseBranch: try c.decode(String.self, forKey: .baseBranch),
                workBranch: try c.decode(String.self, forKey: .workBranch))
        case "assistant_delta":
            self = .assistantDelta(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                text: try c.decode(String.self, forKey: .text))
        case "tool_call":
            self = .toolCall(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                callId: try c.decode(String.self, forKey: .callId),
                tool: try c.decode(String.self, forKey: .tool),
                summary: try c.decode(String.self, forKey: .summary))
        case "tool_result":
            self = .toolResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                callId: try c.decode(String.self, forKey: .callId),
                ok: try c.decode(Bool.self, forKey: .ok),
                output: try c.decode(String.self, forKey: .output))
        case "diff":
            self = .diff(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                patch: try c.decode(String.self, forKey: .patch),
                added: try c.decode(Int.self, forKey: .added),
                removed: try c.decode(Int.self, forKey: .removed))
        case "permission_request":
            self = .permissionRequest(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                requestId: try c.decode(String.self, forKey: .requestId),
                tool: try c.decode(String.self, forKey: .tool),
                summary: try c.decode(String.self, forKey: .summary))
        case "session_done":
            self = .sessionDone(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                stopReason: try c.decodeIfPresent(String.self, forKey: .stopReason))
        case "pr_created":
            self = .prCreated(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                url: try c.decode(String.self, forKey: .url))
        case "error":
            self = .error(
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId),
                message: try c.decode(String.self, forKey: .message))
        case "skills_sync":
            self = .skillsSync(skills: try c.decode([Skill].self, forKey: .skills))
        case "mcp_sync":
            self = .mcpSync(servers: try c.decode([MCPServer].self, forKey: .servers))
        case "terminal_data":
            self = .terminalData(
                terminalId: try c.decode(String.self, forKey: .terminalId),
                stream: try c.decode(String.self, forKey: .stream),
                data: try c.decode(String.self, forKey: .data))
        case "terminal_control":
            self = .terminalControl(
                terminalId: try c.decode(String.self, forKey: .terminalId),
                event: try c.decode(String.self, forKey: .event),
                code: try c.decode(Int.self, forKey: .code))
        case "file_list_result":
            self = .fileListResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                entries: try c.decode([FileEntryPayload].self, forKey: .entries),
                diff: try c.decodeIfPresent(String.self, forKey: .diff))
        case "file_read_result":
            self = .fileReadResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                content: try c.decode(String.self, forKey: .content),
                truncated: try c.decode(Bool.self, forKey: .truncated))
        case "port_list_result":
            self = .portListResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                ports: try c.decode([PortEntryPayload].self, forKey: .ports))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown server message type: \(type)")
        }
    }
}

/// String coding key for building heterogeneous JSON objects.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
