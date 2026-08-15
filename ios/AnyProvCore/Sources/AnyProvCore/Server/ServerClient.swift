import Foundation

/// Connects the app to the desktop coding server: HTTP pairing to obtain a
/// bearer token, then a WebSocket carrying the agent protocol. Inbound frames
/// are exposed as an `AsyncStream<ServerMessage>`.
public actor ServerClient {
    public struct Endpoint: Sendable, Equatable, Hashable {
        /// e.g. "http://192.168.1.20:4319"
        public let baseURL: URL
        public init(baseURL: URL) { self.baseURL = baseURL }
        public init?(host: String) {
            var raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
            // Allow bare host:port from manual entry.
            if !raw.contains("://") {
                raw = "http://\(raw)"
            }
            // Drop trailing slash so path replacement is predictable.
            while raw.count > 8, raw.hasSuffix("/") {
                raw.removeLast()
            }
            guard var components = URLComponents(string: raw),
                  let hostName = components.host, !hostName.isEmpty else {
                return nil
            }
            // Default companion port when the user types a bare IP / hostname.
            if components.port == nil {
                let scheme = (components.scheme ?? "http").lowercased()
                if scheme == "http" || scheme == "ws" {
                    components.port = 4319
                }
            }
            guard let url = components.url else { return nil }
            self.baseURL = url
        }
    }

    public enum ClientError: Error, LocalizedError {
        case badURL
        case pairFailed(String)
        case notConnected
        case connectFailed(String)
        case sendFailed(String)
        case httpFailed(String)

        public var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid server address."
            case let .pairFailed(m): return "Pairing failed: \(m)"
            case .notConnected: return "Not connected to a server."
            case let .connectFailed(m): return m
            case let .sendFailed(m): return m
            case let .httpFailed(m): return m
            }
        }
    }

    private let baseConfiguration: URLSessionConfiguration
    private var task: URLSessionWebSocketTask?
    /// Keeps the open/close delegate alive for the lifetime of the socket.
    private var openBridge: WebSocketOpenBridge?
    /// Generation counter so a late receive loop from a prior socket can't
    /// tear down a newer connection.
    private var connectionGeneration: UInt64 = 0

    public init(session: URLSession? = nil) {
        if let session {
            self.baseConfiguration = session.configuration
        } else {
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 300
            // Avoid HTTP/3 / multipath surprises on LAN WebSockets.
            #if os(iOS)
            config.multipathServiceType = .none
            #endif
            self.baseConfiguration = config
        }
    }

    // MARK: Pairing

    /// Exchange a pairing code for a bearer token.
    public func pair(endpoint: Endpoint, code: String, deviceName: String) async throws -> PairResponse {
        var req = URLRequest(url: endpoint.baseURL.appendingPathComponent("pair"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONEncoder().encode(PairRequest(code: code, deviceName: deviceName))

        let session = URLSession(configuration: baseConfiguration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ClientError.pairFailed(body)
        }
        return try JSONDecoder().decode(PairResponse.self, from: data)
    }

    /// List Metal models installed on the paired desktop (coding agent).
    public func listDesktopMetalModels(
        endpoint: Endpoint,
        token: String
    ) async throws -> DesktopMetalModelsResponse {
        var req = URLRequest(url: endpoint.baseURL.appendingPathComponent("metal/models"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        let session = URLSession(configuration: baseConfiguration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.httpFailed("No HTTP response from desktop.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            if http.statusCode == 401 {
                throw ClientError.httpFailed("Desktop rejected the pairing token. Re-pair and try again.")
            }
            throw ClientError.httpFailed(body)
        }
        return try JSONDecoder().decode(DesktopMetalModelsResponse.self, from: data)
    }

    // MARK: WebSocket

    /// Open the session WebSocket, wait until it is actually connected and still
    /// alive, then return a stream of decoded messages.
    public func connect(endpoint: Endpoint, token: String) async throws -> AsyncStream<ServerMessage> {
        // Tear down any previous socket on this client.
        disconnect()
        let generation = connectionGeneration

        let wsURL = try Self.makeSessionURL(endpoint: endpoint, token: token)

        let bridge = WebSocketOpenBridge()
        let session = URLSession(
            configuration: baseConfiguration,
            delegate: bridge,
            delegateQueue: nil
        )
        // Retain session via bridge so the task's session isn't deallocated.
        bridge.retainSession = session

        let task = session.webSocketTask(with: wsURL)
        self.task = task
        self.openBridge = bridge
        task.resume()

        // Wait until the socket is open (or fails).
        do {
            try await bridge.waitUntilOpen(timeoutSeconds: 20)
        } catch {
            disconnect()
            throw ClientError.connectFailed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        // Server may close immediately after the handshake (bad/expired token).
        // Give the close frame a moment to arrive before we claim success.
        try await Task.sleep(nanoseconds: 120_000_000) // 120ms
        if let closeError = bridge.closedAfterOpenError {
            disconnect()
            throw ClientError.connectFailed(closeError)
        }
        guard task.state == .running else {
            let reason = bridge.closedAfterOpenError
                ?? "WebSocket not running after open (state \(task.state.rawValue)). Is the desktop online? Re-pair if it restarted."
            disconnect()
            throw ClientError.connectFailed(reason)
        }

        let streamTask = task
        return AsyncStream { continuation in
            let receiver = Task { [weak self] in
                await self?.receiveLoop(
                    task: streamTask,
                    generation: generation,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [weak self] _ in
                receiver.cancel()
                Task {
                    // Only tear down if this stream still owns the live socket.
                    await self?.disconnect(ifGeneration: generation)
                }
            }
        }
    }

    /// Open a short-lived session and wait for `remote_endpoint` with a public URL.
    /// Used after LAN pair so the phone can switch to the stable tunnel URL.
    public func waitForRemoteEndpoint(
        endpoint: Endpoint,
        token: String,
        timeoutSeconds: TimeInterval = 50
    ) async throws -> (url: String, provider: String?) {
        let stream = try await connect(endpoint: endpoint, token: token)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        for await msg in stream {
            if Date() > deadline { break }
            if case let .remoteEndpoint(status, url, provider, error) = msg {
                if status == "up", let url, !url.isEmpty {
                    disconnect()
                    return (url, provider)
                }
                if status == "error" {
                    disconnect()
                    throw ClientError.pairFailed(error ?? "Tunnel failed to start.")
                }
            }
        }
        disconnect()
        throw ClientError.pairFailed("Timed out waiting for a public tunnel URL.")
    }

    /**
     Request a (re)published public tunnel URL over a short-lived LAN socket.
     When `force` is true, ignores any pre-existing `remote_endpoint` "up" from
     auto-push until the server acknowledges a restart (`starting` → `up`).
     */
    public func requestRemoteEndpoint(
        endpoint: Endpoint,
        token: String,
        force: Bool = true,
        timeoutSeconds: TimeInterval = 50
    ) async throws -> (url: String, provider: String?) {
        let stream = try await connect(endpoint: endpoint, token: token)
        try await send(.remoteEndpointRequest(force: force))
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var seenStarting = false
        for await msg in stream {
            if Date() > deadline { break }
            if case let .remoteEndpoint(status, url, provider, error) = msg {
                if status == "starting" {
                    seenStarting = true
                    continue
                }
                if status == "up", let url, !url.isEmpty {
                    // After force, skip a stale auto-push that arrived before "starting".
                    if force && !seenStarting { continue }
                    disconnect()
                    return (url, provider)
                }
                if status == "error" {
                    // Ignore early errors unless we've begun a forced restart.
                    if force && !seenStarting { continue }
                    disconnect()
                    throw ClientError.pairFailed(error ?? "Tunnel failed to start.")
                }
            }
        }
        disconnect()
        throw ClientError.pairFailed("Timed out waiting for a public tunnel URL.")
    }

    private func receiveLoop(
        task: URLSessionWebSocketTask,
        generation: UInt64,
        continuation: AsyncStream<ServerMessage>.Continuation
    ) async {
        let decoder = JSONDecoder()
        while !Task.isCancelled {
            // Bail if a newer connect() replaced this socket.
            if generation != connectionGeneration {
                continuation.finish()
                return
            }
            do {
                let frame = try await task.receive()
                let data: Data?
                switch frame {
                case let .string(text): data = text.data(using: .utf8)
                case let .data(d): data = d
                @unknown default: data = nil
                }
                guard let data else { continue }
                if let msg = try? decoder.decode(ServerMessage.self, from: data) {
                    continuation.yield(msg)
                }
            } catch {
                continuation.finish()
                return
            }
        }
        continuation.finish()
    }

    /// Send a client message over the open WebSocket.
    public func send(_ message: ClientMessage) async throws {
        guard let task else {
            throw ClientError.notConnected
        }
        if let closed = openBridge?.closedAfterOpenError {
            throw ClientError.sendFailed(closed)
        }
        guard task.state == .running else {
            throw ClientError.sendFailed(
                "Socket is not connected (state \(task.state.rawValue)). Re-pair if the desktop restarted."
            )
        }

        let data = try JSONEncoder().encode(message)
        let text = String(data: data, encoding: .utf8) ?? "{}"

        // Retry briefly if the OS reports a transient not-connected race.
        var lastError: Error?
        for attempt in 0..<10 {
            if let closed = openBridge?.closedAfterOpenError {
                throw ClientError.sendFailed(closed)
            }
            guard task.state == .running else {
                throw ClientError.sendFailed(
                    "Socket is not connected. Re-pair if the desktop restarted, or switch Local/Tunnel."
                )
            }
            do {
                try await task.send(.string(text))
                return
            } catch {
                lastError = error
                let ns = error as NSError
                let transient =
                    (ns.domain == NSPOSIXErrorDomain && ns.code == 57) // ENOTCONN
                    || ns.localizedDescription.localizedCaseInsensitiveContains("not connected")
                    || ns.localizedDescription.localizedCaseInsensitiveContains("socket is not connected")
                if !transient || attempt == 9 { break }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
        let detail = lastError?.localizedDescription ?? "send failed"
        throw ClientError.sendFailed(
            "\(detail). If the desktop was restarted, open Settings → Pair server again."
        )
    }

    public func disconnect() {
        connectionGeneration &+= 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        openBridge?.invalidate()
        openBridge = nil
    }

    /// Tear down only if `generation` is still the active connection.
    private func disconnect(ifGeneration generation: UInt64) {
        guard generation == connectionGeneration else { return }
        disconnect()
    }

    private static func makeSessionURL(endpoint: Endpoint, token: String) throws -> URL {
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)
        let scheme = endpoint.baseURL.scheme?.lowercased()
        components?.scheme = scheme == "https" ? "wss" : "ws"
        // Replace path with /session (pair base has no API path segment).
        components?.path = "/session"
        components?.queryItems = [
            URLQueryItem(name: "token", value: token),
        ]
        // percentEncodedQuery is built by URLComponents from queryItems.
        guard let wsURL = components?.url else { throw ClientError.badURL }
        return wsURL
    }
}

// MARK: - Open handshake

/// Bridges URLSession WebSocket open/close into async waiters.
private final class WebSocketOpenBridge: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var retainSession: URLSession?

    private let lock = NSLock()
    private var opened = false
    private var failed: Error?
    /// Set when the socket closes *after* a successful open (e.g. 4001 unauthorized).
    private(set) var closedAfterOpenError: String?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var invalid = false

    func waitUntilOpen(timeoutSeconds: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.lock.lock()
                    if self.invalid {
                        self.lock.unlock()
                        cont.resume(throwing: ServerClient.ClientError.connectFailed("Connection cancelled."))
                        return
                    }
                    if let failed = self.failed {
                        self.lock.unlock()
                        cont.resume(throwing: failed)
                        return
                    }
                    if self.opened {
                        self.lock.unlock()
                        cont.resume()
                        return
                    }
                    self.waiters.append(cont)
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ServerClient.ClientError.connectFailed(
                    "Timed out waiting for WebSocket open. Is the desktop running on this network?"
                )
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func invalidate() {
        lock.lock()
        invalid = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        retainSession?.finishTasksAndInvalidate()
        retainSession = nil
        for w in pending {
            w.resume(throwing: ServerClient.ClientError.connectFailed("Connection cancelled."))
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pending { w.resume() }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let message = Self.describeClose(code: closeCode, reason: reason)
        lock.lock()
        if opened {
            closedAfterOpenError = message
            lock.unlock()
            return
        }
        lock.unlock()
        failOpen(ServerClient.ClientError.connectFailed(message))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let message = error.localizedDescription
        lock.lock()
        if opened {
            if closedAfterOpenError == nil {
                closedAfterOpenError = message
            }
            lock.unlock()
            return
        }
        lock.unlock()
        failOpen(ServerClient.ClientError.connectFailed(message))
    }

    private func failOpen(_ error: Error) {
        lock.lock()
        if opened {
            lock.unlock()
            return
        }
        failed = error
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pending { w.resume(throwing: error) }
    }

    private static func describeClose(
        code: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) -> String {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let raw = code.rawValue
        if raw == 4001 || reasonText.localizedCaseInsensitiveContains("unauthorized") {
            return "Unauthorized — re-pair with the desktop (token expired or server restarted)."
        }
        if !reasonText.isEmpty {
            return "WebSocket closed (\(raw)): \(reasonText)"
        }
        return "WebSocket closed (code \(raw))."
    }
}
