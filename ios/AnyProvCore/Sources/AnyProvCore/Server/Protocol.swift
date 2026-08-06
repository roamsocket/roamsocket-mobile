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
    case trusted, limited, none, custom

    public var displayName: String {
        switch self {
        case .trusted: return "Trusted network access"
        case .limited: return "Limited network access"
        case .none: return "No network access"
        case .custom: return "Custom"
        }
    }

    public var subtitle: String {
        switch self {
        case .trusted:
            return "Downloads packages from verified sources."
        case .limited:
            return "Unrestricted internet access for maximum flexibility."
        case .none:
            return "Blocks internet access for maximum security."
        case .custom:
            return "Create a list of allowed domains."
        }
    }
}

public struct EnvironmentConfig: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var networkAccess: NetworkAccess
    public var allowedDomains: [String]
    public var variables: [String: String]

    public var id: String { name }

    public init(
        name: String,
        networkAccess: NetworkAccess = .trusted,
        allowedDomains: [String] = [],
        variables: [String: String] = [:]
    ) {
        self.name = name
        self.networkAccess = networkAccess
        self.allowedDomains = allowedDomains
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
    /// Optional override for custom / proxy endpoints (e.g. `https://host/v1`).
    public var baseURL: String?
    /// API shape when `baseURL` is set. Defaults to OpenAI-compatible on the server.
    public var apiStyle: CustomProviderStyle?

    public init(
        provider: ProviderID,
        model: String,
        effort: Effort = .high,
        apiKey: String,
        baseURL: String? = nil,
        apiStyle: CustomProviderStyle? = nil
    ) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.apiStyle = apiStyle
    }

    enum CodingKeys: String, CodingKey {
        case provider, model, effort, apiKey
        case baseURL = "baseUrl"
        case apiStyle
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
    /// Public HTTPS base URL when a tunnel is already up at pair time.
    public let publicUrl: String?

    public init(token: String, serverName: String, serverVersion: String, publicUrl: String? = nil) {
        self.token = token
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.publicUrl = publicUrl
    }
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
    /// Optional `model` rebinds the agent for this turn (mid-session model switch).
    case userMessage(sessionId: String, text: String, model: ModelSelection? = nil)
    case permissionResponse(sessionId: String, requestId: String, decision: PermissionDecision)
    case interrupt(sessionId: String)
    case createPR(sessionId: String, title: String, body: String)
    /// Instant commit / push / open-PR from the session UI.
    case gitPublish(sessionId: String, message: String, commit: Bool, push: Bool, openPr: Bool)
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
    case fileWrite(sessionId: String, path: String, content: String)
    case portList(sessionId: String)
    case tunnelStart(sessionId: String, port: Int, provider: String)
    case tunnelStop(sessionId: String, tunnelId: String)
    case tunnelList(sessionId: String)
    /// Ask desktop to (re)publish the coding-server public tunnel (`remote_endpoint`).
    /// `force: true` tears down the existing access tunnel and starts a new one.
    case remoteEndpointRequest(force: Bool = false)

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
        case let .userMessage(sessionId, text, model):
            try c.encode("user_message", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
            try c.encode(text, forKey: .init("text"))
            if let model { try c.encode(model, forKey: .init("model")) }
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
        case let .gitPublish(sessionId, message, commit, push, openPr):
            try c.encode("git_publish", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
            try c.encode(message, forKey: .init("message"))
            try c.encode(commit, forKey: .init("commit"))
            try c.encode(push, forKey: .init("push"))
            try c.encode(openPr, forKey: .init("openPr"))
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
        case let .fileWrite(sessionId, path, content):
            try c.encode("file_write", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
            try c.encode(path, forKey: .init("path"))
            try c.encode(content, forKey: .init("content"))
        case let .portList(sessionId):
            try c.encode("port_list", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
        case let .tunnelStart(sessionId, port, provider):
            try c.encode("tunnel_start", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
            try c.encode(port, forKey: .init("port"))
            try c.encode(provider, forKey: .init("provider"))
        case let .tunnelStop(sessionId, tunnelId):
            try c.encode("tunnel_stop", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
            try c.encode(tunnelId, forKey: .init("tunnelId"))
        case let .tunnelList(sessionId):
            try c.encode("tunnel_list", forKey: .init("type"))
            try c.encode(sessionId, forKey: .init("sessionId"))
        case let .remoteEndpointRequest(force):
            try c.encode("remote_endpoint_request", forKey: .init("type"))
            if force { try c.encode(true, forKey: .init("force")) }
        }
    }
}

/// MCP server configuration sent on `create_session`.
/// Wire shape must match desktop `MCPServer` in `protocol.ts`.
public struct MCPServerConfig: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let command: String
    public let args: [String]
    public let env: [String: String]
    public let isEnabled: Bool

    public init(
        id: String,
        name: String,
        description: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.command = command
        self.args = args
        self.env = env
        self.isEnabled = isEnabled
    }

    public init(_ server: MCPServer) {
        self.id = server.id
        self.name = server.name
        self.description = server.description
        self.command = server.command
        self.args = server.args
        self.env = server.env
        self.isEnabled = server.isEnabled
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
    case gitResult(sessionId: String, action: String, ok: Bool, detail: String, url: String?)
    case error(sessionId: String?, message: String)
    case skillsSync(skills: [Skill])
    case mcpSync(servers: [MCPServer])
    case terminalData(terminalId: String, stream: String, data: String)
    case terminalControl(terminalId: String, event: String, code: Int)
    case fileListResult(sessionId: String, path: String, entries: [FileEntryPayload], diff: String?, changes: [FileChangePayload]?)
    case fileReadResult(sessionId: String, path: String, content: String, truncated: Bool, diff: String?)
    case fileWriteResult(sessionId: String, path: String, ok: Bool, message: String?)
    case portListResult(sessionId: String, ports: [PortEntryPayload])
    case tunnelStatus(sessionId: String, tunnels: [TunnelPayload], availableProviders: [String])
    /// Coding-server public URL after auto tunnel starts (phone should switch here).
    case remoteEndpoint(status: String, url: String?, provider: String?, error: String?)

    public struct FileEntryPayload: Codable, Hashable, Sendable {
        public let name: String
        public let path: String
        public let isDirectory: Bool
        public let size: Int
        public let modifiedAt: String
        public let changeStatus: String?
    }
    public struct FileChangePayload: Codable, Hashable, Sendable {
        public let path: String
        public let status: String
    }
    public struct PortEntryPayload: Codable, Hashable, Sendable {
        public let port: Int
        public let pid: Int
        public let command: String
    }
    public struct TunnelPayload: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let port: Int
        public let provider: String
        public let status: String
        public let url: String?
        public let error: String?
    }

    private enum K: String, CodingKey {
        case type, sessionId, workdir, baseBranch, workBranch, text, callId, tool
        case summary, ok, output, path, patch, added, removed, requestId, stopReason, url, message
        case action, detail
        case skills, servers
        case terminalId, stream, data, event, code
        case entries, diff, content, truncated, ports, port, pid, command
        case name, isDirectory, size, modifiedAt, changeStatus, changes
        case tunnels, availableProviders, provider, status, error, tunnelId
    }

    // CodingKeys already cover remote_endpoint fields: status, url, provider, error

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
        case "git_result":
            self = .gitResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                action: try c.decode(String.self, forKey: .action),
                ok: try c.decode(Bool.self, forKey: .ok),
                detail: try c.decode(String.self, forKey: .detail),
                url: try c.decodeIfPresent(String.self, forKey: .url))
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
                diff: try c.decodeIfPresent(String.self, forKey: .diff),
                changes: try c.decodeIfPresent([FileChangePayload].self, forKey: .changes))
        case "file_read_result":
            self = .fileReadResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                content: try c.decode(String.self, forKey: .content),
                truncated: try c.decode(Bool.self, forKey: .truncated),
                diff: try c.decodeIfPresent(String.self, forKey: .diff))
        case "file_write_result":
            self = .fileWriteResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                ok: try c.decode(Bool.self, forKey: .ok),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "port_list_result":
            self = .portListResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                ports: try c.decode([PortEntryPayload].self, forKey: .ports))
        case "tunnel_status":
            self = .tunnelStatus(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                tunnels: try c.decode([TunnelPayload].self, forKey: .tunnels),
                availableProviders: try c.decode([String].self, forKey: .availableProviders))
        case "remote_endpoint":
            self = .remoteEndpoint(
                status: try c.decode(String.self, forKey: .status),
                url: try c.decodeIfPresent(String.self, forKey: .url),
                provider: try c.decodeIfPresent(String.self, forKey: .provider),
                error: try c.decodeIfPresent(String.self, forKey: .error))
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
