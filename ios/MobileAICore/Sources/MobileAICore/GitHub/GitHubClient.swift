import Foundation

/// A GitHub repository shown in the repository picker (IMG_0991).
public struct GitHubRepo: Codable, Hashable, Sendable, Identifiable {
    public let fullName: String        // "owner/name"
    public let name: String
    public let owner: String
    public let isPrivate: Bool
    public let defaultBranch: String
    public let pushedAt: Date?

    public var id: String { fullName }
}

/// The pending state of a Device Flow authorization.
public struct DeviceCode: Sendable {
    public let deviceCode: String
    public let userCode: String          // shown to the user to type on github.com
    public let verificationURI: String   // usually https://github.com/login/device
    public let interval: Int             // seconds between polls
    public let expiresIn: Int
}

public enum GitHubError: Error, LocalizedError {
    case http(status: Int, body: String)
    case authorizationPending
    case slowDown
    case expired
    case denied
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, body): return "GitHub HTTP \(status): \(body)"
        case .authorizationPending: return "Waiting for you to authorize on github.com…"
        case .slowDown: return "Polling too fast; slowing down."
        case .expired: return "The device code expired. Start again."
        case .denied: return "Authorization was denied."
        case let .decoding(msg): return "Failed to decode GitHub response: \(msg)"
        }
    }
}

/// GitHub Device Flow (no client secret, ideal for a native app) plus repo
/// listing. Supply your own OAuth app client id. A Personal Access Token can
/// be used directly with `listRepos(token:)`, skipping the flow entirely.
public struct GitHubClient: Sendable {
    private let clientID: String
    private let http: HTTPClient
    private let scope: String

    public init(
        clientID: String,
        scope: String = "repo read:user",
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.clientID = clientID
        self.scope = scope
        self.http = http
    }

    // MARK: Device Flow

    public func requestDeviceCode() async throws -> DeviceCode {
        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody(["client_id": clientID, "scope": scope])

        let (data, response) = try await http.data(for: req)
        try expectOK(data, response)

        struct Resp: Decodable {
            let device_code: String
            let user_code: String
            let verification_uri: String
            let interval: Int
            let expires_in: Int
        }
        do {
            let r = try JSONDecoder().decode(Resp.self, from: data)
            return DeviceCode(
                deviceCode: r.device_code,
                userCode: r.user_code,
                verificationURI: r.verification_uri,
                interval: r.interval,
                expiresIn: r.expires_in
            )
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    /// One poll for the access token. Returns the token, or throws
    /// `.authorizationPending` / `.slowDown` while the user hasn't finished.
    public func pollForToken(deviceCode: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody([
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])

        let (data, response) = try await http.data(for: req)
        try expectOK(data, response)

        struct Resp: Decodable {
            let access_token: String?
            let error: String?
        }
        let r = (try? JSONDecoder().decode(Resp.self, from: data))
        if let token = r?.access_token { return token }
        switch r?.error {
        case "authorization_pending": throw GitHubError.authorizationPending
        case "slow_down": throw GitHubError.slowDown
        case "expired_token": throw GitHubError.expired
        case "access_denied": throw GitHubError.denied
        default:
            throw GitHubError.decoding(String(data: data, encoding: .utf8) ?? "unknown")
        }
    }

    /// Convenience: poll on the server-provided interval until authorized.
    public func awaitToken(_ code: DeviceCode) async throws -> String {
        var delay = max(code.interval, 1)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            do {
                return try await pollForToken(deviceCode: code.deviceCode)
            } catch GitHubError.authorizationPending {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            } catch GitHubError.slowDown {
                delay += 5
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
        throw GitHubError.expired
    }

    // MARK: Repos

    /// List repositories the token can access, most recently pushed first.
    public func listRepos(token: String, perPage: Int = 100) async throws -> [GitHubRepo] {
        var components = URLComponents(string: "https://api.github.com/user/repos")!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "sort", value: "pushed"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
        ]
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("code-mobile-ai", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.data(for: req)
        try expectOK(data, response)

        struct Raw: Decodable {
            struct Owner: Decodable { let login: String }
            let name: String
            let full_name: String
            let `private`: Bool
            let default_branch: String
            let pushed_at: String?
            let owner: Owner
        }
        do {
            let raw = try JSONDecoder().decode([Raw].self, from: data)
            let iso = ISO8601DateFormatter()
            return raw.map {
                GitHubRepo(
                    fullName: $0.full_name,
                    name: $0.name,
                    owner: $0.owner.login,
                    isPrivate: $0.private,
                    defaultBranch: $0.default_branch,
                    pushedAt: $0.pushed_at.flatMap { iso.date(from: $0) }
                )
            }
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    // MARK: Helpers

    private func formBody(_ params: [String: String]) -> Data {
        params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private func expectOK(_ data: Data, _ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubError.http(status: response.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

private extension CharacterSet {
    /// URL query value encoding that escapes `&`, `=`, `+`, etc.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
