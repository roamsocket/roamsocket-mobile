import Combine
import Foundation
import Network

/// A desktop coding server discovered on the local network via Bonjour.
public struct DiscoveredServer: Identifiable, Hashable, Sendable {
    public var id: String
    /// Bonjour instance name (includes machine hostname when advertised).
    public var name: String
    /// Resolved IPv4/IPv6 host for HTTP pairing.
    public var host: String
    public var port: Int
    /// Optional TXT `name` (product server name).
    public var serverName: String?
    public var version: String?

    public init(
        id: String,
        name: String,
        host: String,
        port: Int,
        serverName: String? = nil,
        version: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.serverName = serverName
        self.version = version
    }

    /// Base URL for `ServerClient` pairing, e.g. `http://192.168.1.20:4319`.
    public var baseURLString: String {
        if host.contains(":") {
            return "http://[\(host)]:\(port)"
        }
        return "http://\(host):\(port)"
    }

    public var displayTitle: String {
        if let serverName, !serverName.isEmpty { return serverName }
        return name
    }

    public var displaySubtitle: String {
        var parts: [String] = [baseURLString]
        if let version, !version.isEmpty {
            parts.append("v\(version)")
        }
        return parts.joined(separator: " · ")
    }
}

/// Bonjour service type published by the desktop companion.
/// Must match `APC_BONJOUR_TYPE` / `BONJOUR_SERVICE_TYPE` in
/// `desktop-server/src/discovery.ts` / `product.ts` and `NSBonjourServices`
/// in the app Info.plist.
public enum ServerDiscovery {
    public static let bonjourType = "_codesocket._tcp"
}

/// Browses the LAN for CodeSocket desktop servers.
///
/// Call `start()` when the pairing screen appears and `stop()` on dismiss.
/// Results stream into `servers` on the main queue.
public final class ServerBrowser: ObservableObject {
    @Published public private(set) var servers: [DiscoveredServer] = []
    @Published public private(set) var isBrowsing: Bool = false
    @Published public private(set) var lastError: String?

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.anyprovcode.server-browser")
    private let lock = NSLock()

    public init() {}

    deinit {
        browser?.cancel()
        lock.lock()
        let connections = Array(resolvers.values)
        resolvers.removeAll()
        lock.unlock()
        connections.forEach { $0.cancel() }
    }

    public func start() {
        stop()
        DispatchQueue.main.async {
            self.lastError = nil
            self.isBrowsing = true
        }

        let descriptor = NWBrowser.Descriptor.bonjour(type: ServerDiscovery.bonjourType, domain: "local.")
        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: params)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self.isBrowsing = true
                    self.lastError = nil
                case .failed(let error):
                    self.isBrowsing = false
                    self.lastError = error.localizedDescription
                case .cancelled:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results)
        }

        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        lock.lock()
        let connections = Array(resolvers.values)
        resolvers.removeAll()
        lock.unlock()
        connections.forEach { $0.cancel() }
        DispatchQueue.main.async {
            self.isBrowsing = false
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        let serviceKeys = Set(results.compactMap { Self.serviceKey(for: $0) })

        DispatchQueue.main.async {
            self.servers.removeAll { !serviceKeys.contains($0.id) }
        }

        lock.lock()
        for key in resolvers.keys where !serviceKeys.contains(key) {
            resolvers[key]?.cancel()
            resolvers[key] = nil
        }
        lock.unlock()

        for result in results {
            guard let key = Self.serviceKey(for: result) else { continue }
            var alreadyHave = false
            DispatchQueue.main.sync {
                alreadyHave = self.servers.contains(where: { $0.id == key })
            }
            if alreadyHave { continue }

            lock.lock()
            let resolving = resolvers[key] != nil
            lock.unlock()
            if resolving { continue }

            resolve(result, key: key)
        }
    }

    private static func serviceKey(for result: NWBrowser.Result) -> String? {
        if case let .service(name: name, type: type, domain: domain, interface: _) = result.endpoint {
            return "\(name).\(type).\(domain)"
        }
        return nil
    }

    private func resolve(_ result: NWBrowser.Result, key: String) {
        let txtName: String?
        let txtVersion: String?
        if case let .bonjour(txt) = result.metadata {
            txtName = Self.stringTXT(txt, key: "name")
            txtVersion = Self.stringTXT(txt, key: "version")
        } else {
            txtName = nil
            txtVersion = nil
        }

        let serviceName: String
        if case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint {
            serviceName = name
        } else {
            serviceName = "Desktop server"
        }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        lock.lock()
        resolvers[key] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let (host, port) = Self.remoteHostPort(of: connection) {
                    let discovered = DiscoveredServer(
                        id: key,
                        name: serviceName,
                        host: host,
                        port: Int(port),
                        serverName: txtName,
                        version: txtVersion
                    )
                    DispatchQueue.main.async {
                        self.upsert(discovered)
                    }
                }
                connection.cancel()
                self.clearResolver(key)
            case .failed, .cancelled:
                self.clearResolver(key)
            default:
                break
            }
        }

        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let still = self.resolvers[key] != nil
            self.lock.unlock()
            if still {
                connection.cancel()
                self.clearResolver(key)
            }
        }
    }

    private func clearResolver(_ key: String) {
        lock.lock()
        resolvers[key] = nil
        lock.unlock()
    }

    private func upsert(_ server: DiscoveredServer) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
            servers.sort {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        }
    }

    private static func stringTXT(_ txt: NWTXTRecord, key: String) -> String? {
        guard let entry = txt.getEntry(for: key) else { return nil }
        switch entry {
        case .string(let s):
            return s.isEmpty ? nil : s
        case .data(let d):
            return String(data: d, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        case .empty, .none:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func remoteHostPort(of connection: NWConnection) -> (String, UInt16)? {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return nil }
        return hostPort(from: endpoint)
    }

    private static func hostPort(from endpoint: NWEndpoint) -> (String, UInt16)? {
        switch endpoint {
        case let .hostPort(host: host, port: port):
            let hostString: String
            switch host {
            case .ipv4(let addr):
                hostString = "\(addr)"
            case .ipv6(let addr):
                hostString = "\(addr)"
            case .name(let name, _):
                hostString = name
            @unknown default:
                return nil
            }
            return (hostString, port.rawValue)
        default:
            return nil
        }
    }
}
