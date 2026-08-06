import Foundation

/// Connects the app to the desktop coding server: HTTP pairing to obtain a
/// bearer token, then a WebSocket carrying the agent protocol. Inbound frames
/// are exposed as an `AsyncStream<ServerMessage>`.
public actor ServerClient {
    public struct Endpoint: Sendable {
        /// e.g. "http://192.168.1.20:4319"
        public let baseURL: URL
        public init(baseURL: URL) { self.baseURL = baseURL }
        public init?(host: String) {
            guard let url = URL(string: host) else { return nil }
            self.baseURL = url
        }
    }

    public enum ClientError: Error, LocalizedError {
        case badURL
        case pairFailed(String)
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid server address."
            case let .pairFailed(m): return "Pairing failed: \(m)"
            case .notConnected: return "Not connected to a server."
            }
        }
    }

    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(session: URLSession = .shared) { self.session = session }

    // MARK: Pairing

    /// Exchange a pairing code for a bearer token.
    public func pair(endpoint: Endpoint, code: String, deviceName: String) async throws -> PairResponse {
        var req = URLRequest(url: endpoint.baseURL.appendingPathComponent("pair"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(PairRequest(code: code, deviceName: deviceName))

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ClientError.pairFailed(body)
        }
        return try JSONDecoder().decode(PairResponse.self, from: data)
    }

    // MARK: WebSocket

    /// Open the session WebSocket and return a stream of decoded messages.
    /// Call `send(_:)` to push client messages once connected.
    public func connect(endpoint: Endpoint, token: String) throws -> AsyncStream<ServerMessage> {
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = endpoint.baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/session"
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let wsURL = components?.url else { throw ClientError.badURL }

        let task = session.webSocketTask(with: wsURL)
        self.task = task
        task.resume()

        return AsyncStream { continuation in
            let receiver = Task { [weak self] in
                await self?.receiveLoop(continuation: continuation)
            }
            continuation.onTermination = { _ in
                receiver.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private func receiveLoop(continuation: AsyncStream<ServerMessage>.Continuation) async {
        guard let task else { continuation.finish(); return }
        let decoder = JSONDecoder()
        while true {
            do {
                let frame = try await task.receive()
                let data: Data?
                switch frame {
                case let .string(text): data = text.data(using: .utf8)
                case let .data(d): data = d
                @unknown default: data = nil
                }
                if let data, let msg = try? decoder.decode(ServerMessage.self, from: data) {
                    continuation.yield(msg)
                }
            } catch {
                continuation.finish()
                return
            }
        }
    }

    /// Send a client message over the open WebSocket.
    public func send(_ message: ClientMessage) async throws {
        guard let task else { throw ClientError.notConnected }
        let data = try JSONEncoder().encode(message)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try await task.send(.string(text))
    }

    public func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
