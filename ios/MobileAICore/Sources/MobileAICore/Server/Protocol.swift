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
    /// When set, override the built-in base URL for `provider`. The provider
    /// must be one of the OpenAI-compatible ids. Mirrors the server's
    /// `ModelSelection.customBaseUrl`.
    public var customBaseUrl: String?

    public init(provider: ProviderID, model: String, effort: Effort = .high, apiKey: String, customBaseUrl: String? = nil) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.apiKey = apiKey
        self.customBaseUrl = customBaseUrl
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

    private enum K: String, CodingKey {
        case type, sessionId, workdir, baseBranch, workBranch, text, callId, tool
        case summary, ok, output, path, patch, added, removed, requestId, stopReason, url, message
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
