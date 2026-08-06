import Foundation
import SwiftUI
import Combine
import AnyProvCore

/// Root observable app state: secrets, model catalog, environments, GitHub
/// token, server pairing, and the current composer selections.
@MainActor
final class AppState: ObservableObject {
    // Secrets & clients
    let secrets: SecretStore
    let catalog: ModelCatalog
    let serverClient = ServerClient()
    let skillManager = SkillManager()
    let mcpManager = MCPManager()
    let artifactStore = ArtifactStore()
    let skillsMCPClient = SkillsMCPClient()
    let codeSessionStore = CodeSessionStore()
    let settingsSync = SettingsSync()

    /// Your GitHub OAuth app client id for Device Flow. Replace before shipping;
    /// can also be provided at runtime via Settings.
    @AppStorage("githubClientID") var githubClientID: String = ""

    // Composer selections (mirror the home screen controls)
    @Published var selectedRepo: GitHubRepo?
    @Published var selectedEnvironment: EnvironmentConfig?
    @Published var selectedModel: AIModel?
    @Published var effort: Effort = .high
    @Published var permissionMode: PermissionMode = .acceptEdits

    /// User-renamed models, keyed by `"provider:modelID"`. Empty entries are
    /// treated as "use the upstream name".
    @Published var modelAliases: [String: String] = [:]

    /// When true, every assistant message expands its Thinking section
    /// by default. When false, thinking collapses behind a one-line preview.
    @AppStorage("alwaysExpandThinking.v1") var alwaysExpandThinking: Bool = false

    /// Branch name prefix for new coding sessions, e.g. `apc/fix-login-a1b2c3d4`.
    @AppStorage("codeBranchPrefix.v1") var codeBranchPrefix: String = "apc"

    /// Active desktop base URL currently used for API/WS (local or tunnel).
    @AppStorage("serverHost.v1") var serverHost: String = ""

    /// LAN address captured at pair time (kept even when active path is tunnel).
    @AppStorage("serverLocalHost.v1") var serverLocalHost: String = ""

    /// Public tunnel URL when the desktop has published one.
    @AppStorage("serverTunnelHost.v1") var serverTunnelHost: String = ""

    /// How the app chooses between LAN and tunnel.
    /// Raw value persisted in AppStorage.
    @AppStorage("serverConnectionPreference.v1") var connectionPreferenceRaw: String = ServerConnectionPreference.smart.rawValue

    /// When non-nil, the iOS app will push its settings to this GitHub
    /// repo on every change (and pull on launch when a token is linked).
    @AppStorage("settingsSyncRepoFullName.v1") var settingsSyncRepoFullName: String?

    // Catalog state
    @Published var providerResults: [ModelCatalog.ProviderResult] = []
    @Published var isLoadingModels = false

    // Custom (user-defined OpenAI-compatible) providers
    @Published var customProviders: [CustomProvider] = []

    // Environments (persisted)
    @Published var environments: [EnvironmentConfig] = []

    // Synced git repos for skills + MCP. Owned by the desktop server (it
    // has `git` in PATH); the iOS app asks the desktop to sync on connect
    // and applies the `skills_sync`/`mcp_sync` payloads to its local cache.
    @Published var skillsRepoURL: String = ""
    @Published var skillsRepoBranch: String = "main"
    @Published var mcpRepoURL: String = ""
    @Published var mcpRepoBranch: String = "main"

    // Server pairing
    @Published var serverEndpoint: ServerClient.Endpoint?
    @Published var serverToken: String?
    @Published var serverName: String?
    @Published var isReconnecting = false
    @Published var reconnectMessage: String?

    /// How the phone reaches the desktop: offline, same network, or public tunnel.
    enum ServerConnectionPath: Equatable {
        case offline
        case local
        case tunnel

        var label: String {
            switch self {
            case .offline: return "Not paired"
            case .local: return "Local"
            case .tunnel: return "Tunnel"
            }
        }

        var systemImage: String {
            switch self {
            case .offline: return "bolt.slash"
            case .local: return "wifi"
            case .tunnel: return "lock.shield"
            }
        }
    }

    /// User preference for which path to use when both LAN and tunnel exist.
    enum ServerConnectionPreference: String, CaseIterable, Identifiable {
        case smart
        case alwaysLocal
        case alwaysTunnel

        var id: String { rawValue }

        var title: String {
            switch self {
            case .smart: return "Smart switch"
            case .alwaysLocal: return "Always local"
            case .alwaysTunnel: return "Always tunnel"
            }
        }

        var subtitle: String {
            switch self {
            case .smart: return "Prefer tunnel when available, fall back to local."
            case .alwaysLocal: return "Stay on the LAN address only."
            case .alwaysTunnel: return "Stay on the public tunnel only."
            }
        }

        var systemImage: String {
            switch self {
            case .smart: return "arrow.triangle.2.circlepath"
            case .alwaysLocal: return "wifi"
            case .alwaysTunnel: return "lock.shield"
            }
        }
    }

    var connectionPreference: ServerConnectionPreference {
        get { ServerConnectionPreference(rawValue: connectionPreferenceRaw) ?? .smart }
        set { connectionPreferenceRaw = newValue.rawValue }
    }

    /// Classify the current paired endpoint as LAN/local or remote tunnel.
    var serverConnectionPath: ServerConnectionPath {
        guard serverToken != nil, let endpoint = serverEndpoint else { return .offline }
        return Self.connectionPath(for: endpoint)
    }

    var localEndpoint: ServerClient.Endpoint? {
        endpoint(fromStored: serverLocalHost)
    }

    var tunnelEndpoint: ServerClient.Endpoint? {
        endpoint(fromStored: serverTunnelHost)
    }

    static func connectionPath(for endpoint: ServerClient.Endpoint) -> ServerConnectionPath {
        let url = endpoint.baseURL
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .offline }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return .local
        }
        if isPrivateLANHost(host) { return .local }
        // Public HTTPS (or any non-private host) is treated as tunnel / remote.
        return .tunnel
    }

    private static func isPrivateLANHost(_ host: String) -> Bool {
        // IPv4 private ranges: 10/8, 172.16–31/12, 192.168/16, link-local 169.254/16
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let a = parts[0], b = parts[1]
        if a == 10 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 169 && b == 254 { return true }
        return false
    }

    private func endpoint(fromStored raw: String) -> ServerClient.Endpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        return ServerClient.Endpoint(host: trimmed)
    }

    private func normalizeHostString(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Remember an endpoint under local and/or tunnel slots without wiping the other.
    private func recordEndpoint(_ endpoint: ServerClient.Endpoint) {
        let path = Self.connectionPath(for: endpoint)
        let host = endpoint.baseURL.absoluteString
        switch path {
        case .local:
            serverLocalHost = host
        case .tunnel:
            serverTunnelHost = host
        case .offline:
            break
        }
    }

    /// Point the active endpoint at `endpoint` and re-key the token for restore.
    private func activateEndpoint(_ endpoint: ServerClient.Endpoint) {
        guard let token = serverToken, !token.isEmpty else { return }
        let host = endpoint.baseURL.absoluteString
        if !serverHost.isEmpty, serverHost != host {
            // Keep token readable from the previous host key during migration.
            secrets.set(token, for: SecretKey.serverToken(serverHost))
        }
        serverEndpoint = endpoint
        serverHost = host
        secrets.set(token, for: SecretKey.serverToken(host))
        // Also store under local/tunnel keys so either path can restore the token.
        if !serverLocalHost.isEmpty {
            secrets.set(token, for: SecretKey.serverToken(serverLocalHost))
        }
        if !serverTunnelHost.isEmpty {
            secrets.set(token, for: SecretKey.serverToken(serverTunnelHost))
        }
        // Keep local/tunnel slots populated from whichever path we just used.
        recordEndpoint(endpoint)
        objectWillChange.send()
    }

    /// Called when a coding session successfully opens a socket on a path —
    /// keeps Settings / the status pill in sync with the live connection.
    func activateEndpointForSession(_ endpoint: ServerClient.Endpoint) {
        activateEndpoint(endpoint)
    }

    // Chat state (per-chat toggles live on `ChatViewModel`; nothing here yet.)

    private let environmentsKey = "environments.v1"
    private let skillsRepoKey = "skillsRepoURL.v1"
    private let skillsBranchKey = "skillsRepoBranch.v1"
    private let mcpRepoKey = "mcpRepoURL.v1"
    private let mcpBranchKey = "mcpRepoBranch.v1"
    private let customProvidersKey = "customProviders.v1"
    private let modelAliasesKey = "modelAliases.v1"
    private let serverNameKey = "serverName.v1"
    private var bag = Set<AnyCancellable>()

    init(secrets: SecretStore) {
        self.secrets = secrets
        self.catalog = ModelCatalog()
        // Code home observes AppState; forward session-store mutations so lists refresh.
        codeSessionStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        loadEnvironments()
        loadSyncedRepos()
        loadCustomProviders()
        loadModelAliases()
        seedDefaultEnvironmentIfNeeded()
        restorePairingFromDisk()
        Task { await attemptServerReconnect() }
    }

    // MARK: - Desktop pairing persistence + auto-reconnect

    /// Persist a successful pair so cold launch can reconnect.
    /// Call this with the address the user paired against (LAN or tunnel URL).
    /// A following `applyRemoteEndpoint` may add the other path without wiping this one.
    func savePairing(endpoint: ServerClient.Endpoint, token: String, serverName: String) {
        // Clear any previous host keys so we don't leave orphan tokens.
        for host in [serverHost, serverLocalHost, serverTunnelHost] where !host.isEmpty {
            if host != endpoint.baseURL.absoluteString {
                secrets.set(nil, for: SecretKey.serverToken(host))
            }
        }
        self.serverToken = token
        self.serverName = serverName
        UserDefaults.standard.set(serverName, forKey: serverNameKey)

        // Fresh pair resets both slots, then records this endpoint as local or tunnel.
        serverLocalHost = ""
        serverTunnelHost = ""
        recordEndpoint(endpoint)
        activateEndpoint(endpoint)
    }

    /// Remember the desktop's public tunnel URL while keeping the LAN address.
    /// Activates tunnel when preference is Smart or Always tunnel.
    @discardableResult
    func applyRemoteEndpoint(urlString: String) -> Bool {
        let trimmed = normalizeHostString(urlString)
        guard !trimmed.isEmpty, let endpoint = ServerClient.Endpoint(host: trimmed) else {
            return false
        }
        guard serverToken != nil, !(serverToken ?? "").isEmpty else { return false }

        let previousTunnel = normalizeHostString(serverTunnelHost)
        serverTunnelHost = trimmed
        secrets.set(serverToken, for: SecretKey.serverToken(trimmed))

        let shouldActivate: Bool = {
            switch connectionPreference {
            case .alwaysLocal: return false
            case .alwaysTunnel, .smart: return true
            }
        }()

        if shouldActivate {
            activateEndpoint(endpoint)
            reconnectMessage = "Remote access ready — using secure tunnel."
        } else {
            reconnectMessage = "Tunnel available (preference is Always local)."
        }
        return previousTunnel.caseInsensitiveCompare(trimmed) != .orderedSame || shouldActivate
    }

    /**
     After a LAN pair, open the session WebSocket and wait for the desktop to
     publish a public tunnel URL, then record it (and switch if preference allows).
     Returns a short status line for the pairing UI.
     */
    func upgradePairingToTunnel(timeoutSeconds: TimeInterval = 50) async -> String {
        // Prefer a known LAN endpoint for the wait socket.
        let listenEndpoint = localEndpoint ?? serverEndpoint
        guard let endpoint = listenEndpoint, let token = serverToken, !token.isEmpty else {
            return "Paired (no tunnel)."
        }
        // Already on a tunnel path with no separate LAN — nothing to upgrade.
        if Self.connectionPath(for: endpoint) == .tunnel,
           localEndpoint == nil {
            serverTunnelHost = endpoint.baseURL.absoluteString
            return "Paired via \(endpoint.baseURL.host ?? "remote")."
        }
        do {
            let client = ServerClient()
            let result = try await client.waitForRemoteEndpoint(
                endpoint: endpoint,
                token: token,
                timeoutSeconds: timeoutSeconds
            )
            if applyRemoteEndpoint(urlString: result.url) {
                let provider = result.provider.map { " via \($0)" } ?? ""
                switch connectionPreference {
                case .alwaysLocal:
                    return "Paired on LAN. Tunnel ready\(provider) (preference is Local)."
                case .alwaysTunnel, .smart:
                    return "Paired. Secure tunnel ready\(provider)."
                }
            }
            return "Paired (tunnel \(result.url))."
        } catch {
            return "Paired on LAN. Tunnel unavailable: \(error.localizedDescription)"
        }
    }

    /// Change connection preference and re-resolve active endpoint.
    func setConnectionPreference(_ preference: ServerConnectionPreference) {
        connectionPreference = preference
        Task { await applyConnectionPreference(healthCheck: true) }
    }

    /**
     Pick the active endpoint from local/tunnel slots according to preference.
     Smart mode prefers tunnel when its health check passes, otherwise local.
     */
    func applyConnectionPreference(healthCheck: Bool = true) async {
        guard serverToken != nil, !(serverToken ?? "").isEmpty else { return }

        let local = localEndpoint
        let tunnel = tunnelEndpoint

        // Seed slots from the current active host if they were never split.
        if local == nil, tunnel == nil, let active = serverEndpoint {
            recordEndpoint(active)
        }

        let localNow = localEndpoint
        let tunnelNow = tunnelEndpoint

        switch connectionPreference {
        case .alwaysLocal:
            if let localNow {
                let ok = healthCheck ? await isEndpointReachable(localNow) : true
                if ok {
                    activateEndpoint(localNow)
                    reconnectMessage = nil
                    return
                }
                reconnectMessage = "Local desktop not reachable."
            } else {
                reconnectMessage = "No local address saved — pair on the same Wi‑Fi first."
            }

        case .alwaysTunnel:
            if let tunnelNow {
                let ok = healthCheck ? await isEndpointReachable(tunnelNow) : true
                if ok {
                    activateEndpoint(tunnelNow)
                    reconnectMessage = nil
                    return
                }
                reconnectMessage = "Tunnel not reachable."
            } else {
                reconnectMessage = "No tunnel URL yet — enable remote access on the desktop."
            }

        case .smart:
            // Prefer tunnel, fall back to local.
            if let tunnelNow {
                let ok = healthCheck ? await isEndpointReachable(tunnelNow) : true
                if ok {
                    activateEndpoint(tunnelNow)
                    reconnectMessage = nil
                    return
                }
            }
            if let localNow {
                let ok = healthCheck ? await isEndpointReachable(localNow) : true
                if ok {
                    activateEndpoint(localNow)
                    reconnectMessage = tunnelNow == nil
                        ? nil
                        : "Tunnel unreachable — using local."
                    return
                }
            }
            // Last resort: still point at preferred path so UI shows intent.
            if let tunnelNow {
                activateEndpoint(tunnelNow)
                reconnectMessage = "Desktop not reachable on tunnel or local."
            } else if let localNow {
                activateEndpoint(localNow)
                reconnectMessage = "Desktop not reachable."
            }
        }
    }

    func clearPairing() {
        for host in [serverHost, serverLocalHost, serverTunnelHost] where !host.isEmpty {
            secrets.set(nil, for: SecretKey.serverToken(host))
        }
        serverEndpoint = nil
        serverToken = nil
        serverName = nil
        serverHost = ""
        serverLocalHost = ""
        serverTunnelHost = ""
        UserDefaults.standard.removeObject(forKey: serverNameKey)
    }

    private func restorePairingFromDisk() {
        // Try active host first, then local, then tunnel.
        let candidates = [serverHost, serverLocalHost, serverTunnelHost]
            .map { normalizeHostString($0) }
            .filter { !$0.isEmpty }
        var token: String?
        var restoredHost: String?
        for host in candidates {
            if let t = secrets.get(SecretKey.serverToken(host)), !t.isEmpty {
                token = t
                restoredHost = host
                break
            }
        }
        guard let token, let restoredHost, let restored = ServerClient.Endpoint(host: restoredHost) else {
            return
        }
        serverToken = token
        serverEndpoint = restored
        if serverHost.isEmpty { serverHost = restoredHost }
        // Backfill slots from the restored path.
        recordEndpoint(restored)
        // If serverHost points elsewhere, prefer that as active.
        if let active = endpoint(fromStored: serverHost) {
            serverEndpoint = active
        }
        serverName = UserDefaults.standard.string(forKey: serverNameKey)
    }

    /// Health-check preferred endpoints and settle on the best path.
    func attemptServerReconnect() async {
        guard serverToken != nil, !(serverToken ?? "").isEmpty else {
            reconnectMessage = nil
            return
        }
        isReconnecting = true
        defer { isReconnecting = false }

        await applyConnectionPreference(healthCheck: true)

        guard let endpoint = serverEndpoint, let token = serverToken else {
            reconnectMessage = "Not paired."
            return
        }

        // Validate token with a short-lived WebSocket on the chosen path.
        do {
            if let name = await fetchServerName(endpoint: endpoint) {
                serverName = name
                UserDefaults.standard.set(name, forKey: serverNameKey)
            }
            let client = ServerClient()
            let stream = try await client.connect(endpoint: endpoint, token: token)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await client.disconnect()
            _ = stream
            if reconnectMessage == nil {
                reconnectMessage = nil
            }
        } catch {
            // If smart/local failed the WS step, try the other path once.
            if connectionPreference == .smart {
                await tryAlternatePath(after: endpoint, error: error)
            } else {
                reconnectMessage = "Could not reconnect: \(error.localizedDescription)"
            }
        }
    }

    private func tryAlternatePath(after failed: ServerClient.Endpoint, error: Error) async {
        let failedPath = Self.connectionPath(for: failed)
        let alternate: ServerClient.Endpoint? = {
            switch failedPath {
            case .tunnel: return localEndpoint
            case .local: return tunnelEndpoint
            case .offline: return localEndpoint ?? tunnelEndpoint
            }
        }()
        guard let alternate, let token = serverToken else {
            reconnectMessage = "Could not reconnect: \(error.localizedDescription)"
            return
        }
        guard await isEndpointReachable(alternate) else {
            reconnectMessage = "Could not reconnect: \(error.localizedDescription)"
            return
        }
        activateEndpoint(alternate)
        do {
            let client = ServerClient()
            let stream = try await client.connect(endpoint: alternate, token: token)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await client.disconnect()
            _ = stream
            reconnectMessage = failedPath == .tunnel
                ? "Tunnel failed — switched to local."
                : "Local failed — switched to tunnel."
        } catch {
            reconnectMessage = "Could not reconnect: \(error.localizedDescription)"
        }
    }

    private func isEndpointReachable(_ endpoint: ServerClient.Endpoint) async -> Bool {
        do {
            var req = URLRequest(url: endpoint.baseURL.appendingPathComponent("health"))
            req.timeoutInterval = 3.5
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func fetchServerName(endpoint: ServerClient.Endpoint) async -> String? {
        do {
            var req = URLRequest(url: endpoint.baseURL.appendingPathComponent("health"))
            req.timeoutInterval = 3.5
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["name"] as? String {
                return name
            }
        } catch {}
        return nil
    }

    // MARK: - Custom providers

    func addCustomProvider(
        label: String,
        baseURL: String,
        apiKey: String,
        style: CustomProviderStyle = .openAI
    ) -> CustomProvider? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = Self.normalizeBaseURL(baseURL)
        guard !trimmedLabel.isEmpty, !normalizedURL.isEmpty else { return nil }
        guard URL(string: normalizedURL) != nil else { return nil }
        let slug = Self.slugify(trimmedLabel)
        guard !slug.isEmpty else { return nil }
        if customProviders.contains(where: { $0.id == slug }) { return nil }
        let provider = CustomProvider(
            id: slug,
            label: trimmedLabel,
            baseURL: normalizedURL,
            style: style
        )
        customProviders.append(provider)
        saveCustomProviders()
        if !apiKey.isEmpty {
            setAPIKey(apiKey, for: provider.providerID)
        }
        return provider
    }

    func updateCustomProvider(
        _ provider: CustomProvider,
        label: String,
        baseURL: String,
        style: CustomProviderStyle,
        apiKey: String?
    ) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = Self.normalizeBaseURL(baseURL)
        guard !trimmedLabel.isEmpty, !normalizedURL.isEmpty else { return }
        guard let idx = customProviders.firstIndex(where: { $0.id == provider.id }) else { return }
        customProviders[idx].label = trimmedLabel
        customProviders[idx].baseURL = normalizedURL
        customProviders[idx].style = style
        saveCustomProviders()
        if let apiKey {
            setAPIKey(apiKey, for: provider.providerID)
        }
    }

    func deleteCustomProvider(_ provider: CustomProvider) {
        customProviders.removeAll { $0.id == provider.id }
        setAPIKey("", for: provider.providerID)
        providerResults.removeAll { $0.provider == provider.providerID }
        if selectedModel?.provider == provider.providerID { selectedModel = nil }
        saveCustomProviders()
    }

    /// Resolve the base URL for a custom provider, if applicable.
    func baseURL(for provider: ProviderID) -> URL? {
        guard let custom = customProvider(for: provider),
              let url = URL(string: custom.baseURL) else {
            return nil
        }
        return url
    }

    /// Resolve API style for a custom provider (built-ins return nil).
    func apiStyle(for provider: ProviderID) -> CustomProviderStyle? {
        customProvider(for: provider)?.style
    }

    func customProvider(for provider: ProviderID) -> CustomProvider? {
        guard let slug = provider.customSlug else { return nil }
        return customProviders.first(where: { $0.id == slug })
    }

    /// Strip trailing slashes and accidental path suffixes users paste from docs.
    static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        let suffixes = ["/chat/completions", "/messages", "/models"]
        for suffix in suffixes where lower.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            while s.hasSuffix("/") { s.removeLast() }
        }
        return s
    }

    private func loadCustomProviders() {
        guard let data = UserDefaults.standard.data(forKey: customProvidersKey),
              let decoded = try? JSONDecoder().decode([CustomProvider].self, from: data)
        else { return }
        customProviders = decoded
    }

    private func saveCustomProviders() {
        if let data = try? JSONEncoder().encode(customProviders) {
            UserDefaults.standard.set(data, forKey: customProvidersKey)
        }
    }

    static func slugify(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed
    }

    // MARK: - Synced repos (URL hints shown in Settings; the desktop owns the real ones)

    func updateSkillsRepo(url: String, branch: String) {
        skillsRepoURL = url
        skillsRepoBranch = branch
        UserDefaults.standard.set(url, forKey: skillsRepoKey)
        UserDefaults.standard.set(branch, forKey: skillsBranchKey)
    }

    func updateMCPRepo(url: String, branch: String) {
        mcpRepoURL = url
        mcpRepoBranch = branch
        UserDefaults.standard.set(url, forKey: mcpRepoKey)
        UserDefaults.standard.set(branch, forKey: mcpBranchKey)
    }

    private func loadSyncedRepos() {
        skillsRepoURL = UserDefaults.standard.string(forKey: skillsRepoKey) ?? ""
        skillsRepoBranch = UserDefaults.standard.string(forKey: skillsBranchKey) ?? "main"
        mcpRepoURL = UserDefaults.standard.string(forKey: mcpRepoKey) ?? ""
        mcpRepoBranch = UserDefaults.standard.string(forKey: mcpBranchKey) ?? "main"
    }

    // MARK: Secrets convenience

    func apiKey(for provider: ProviderID) -> String {
        secrets.get(SecretKey.providerAPIKey(provider)) ?? ""
    }

    /// Key used for live API calls. Local OpenAI-compatible hosts (Ollama, etc.)
    /// often ignore auth — if the user left the key blank on a custom OpenAI-style
    /// provider, send a placeholder bearer token instead of falling back to OpenAI.
    func resolvedAPIKey(for provider: ProviderID) -> String {
        let stored = apiKey(for: provider)
        if !stored.isEmpty { return stored }
        // On-device Metal never needs a cloud key (chat only).
        if provider == .localMetal { return "local" }
        if case .custom = provider, apiStyle(for: provider) == .openAI {
            return "local"
        }
        return ""
    }

    func setAPIKey(_ key: String, for provider: ProviderID) {
        secrets.set(key.isEmpty ? nil : key, for: SecretKey.providerAPIKey(provider))
    }

    var githubToken: String? {
        get { secrets.get(SecretKey.githubToken) }
        set { secrets.set(newValue, for: SecretKey.githubToken) }
    }

    var allModels: [AIModel] {
        providerResults.flatMap(\.models)
    }

    // MARK: Models

    func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        var keys: [ProviderID: String] = [:]
        var customBaseURLs: [ProviderID: URL] = [:]
        var styles: [ProviderID: CustomProviderStyle] = [:]
        for provider in ProviderID.allBuiltInCases {
            if provider == .localMetal {
                keys[provider] = "local"
                continue
            }
            let key = apiKey(for: provider)
            if !key.isEmpty { keys[provider] = key }
        }
        for custom in customProviders {
            let pid = custom.providerID
            // Always try to list customs that have a base URL. resolvedAPIKey
            // supplies a local placeholder for keyless OpenAI-compatible hosts.
            let key = resolvedAPIKey(for: pid)
            if !key.isEmpty { keys[pid] = key }
            if let url = URL(string: custom.baseURL) { customBaseURLs[pid] = url }
            styles[pid] = custom.style
        }
        providerResults = await catalog.fetchAll(
            keys: keys,
            customBaseURLs: customBaseURLs,
            styles: styles
        )
        // Drop a selection that no longer has a key / vanished from catalog.
        if let selected = selectedModel {
            let stillListed = allModels.contains(where: { $0.id == selected.id })
            let canCall = !resolvedAPIKey(for: selected.provider).isEmpty
            if !stillListed || !canCall {
                selectedModel = allModels.first
            }
        } else {
            selectedModel = allModels.first
        }
    }

    // MARK: Environments

    func addOrUpdate(_ env: EnvironmentConfig) {
        if let idx = environments.firstIndex(where: { $0.name == env.name }) {
            environments[idx] = env
        } else {
            environments.append(env)
        }
        saveEnvironments()
    }

    func delete(_ env: EnvironmentConfig) {
        environments.removeAll { $0.name == env.name }
        saveEnvironments()
    }

    private func loadEnvironments() {
        guard let data = UserDefaults.standard.data(forKey: environmentsKey),
              let decoded = try? JSONDecoder().decode([EnvironmentConfig].self, from: data)
        else { return }
        environments = decoded
    }

    private func saveEnvironments() {
        if let data = try? JSONEncoder().encode(environments) {
            UserDefaults.standard.set(data, forKey: environmentsKey)
        }
    }

    private func seedDefaultEnvironmentIfNeeded() {
        if environments.isEmpty {
            let def = EnvironmentConfig(name: "Default", networkAccess: .trusted)
            environments = [def]
            selectedEnvironment = def
            saveEnvironments()
        } else if selectedEnvironment == nil {
            selectedEnvironment = environments.first
        }
    }

    // MARK: Model selection for a session

    /// Build the `ModelSelection` the server needs, pulling the key from Keychain.
    /// Local Metal models are chat-only and never sent to the coding agent.
    func modelSelectionForSession() -> ModelSelection? {
        guard let model = selectedModel else { return nil }
        guard model.provider.supportsCodingAgent else { return nil }
        let key = resolvedAPIKey(for: model.provider)
        guard !key.isEmpty else { return nil }
        let custom = customProvider(for: model.provider)
        return ModelSelection(
            provider: model.provider,
            model: model.modelID,
            effort: effort,
            apiKey: key,
            baseURL: custom?.baseURL,
            apiStyle: custom?.style
        )
    }

    var canStartSession: Bool {
        selectedRepo != nil && modelSelectionForSession() != nil && serverToken != nil
    }

    // MARK: - Model aliases

    /// Stable key for the alias table — survives custom provider slugs.
    static func aliasKey(provider: ProviderID, modelID: String) -> String {
        "\(provider.rawValue):\(modelID)"
    }

    func setAlias(_ alias: String?, for provider: ProviderID, modelID: String) {
        let key = Self.aliasKey(provider: provider, modelID: modelID)
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            modelAliases[key] = trimmed
        } else {
            modelAliases.removeValue(forKey: key)
        }
        saveModelAliases()
    }

    /// Display name shown in the UI: alias if present, otherwise the upstream name.
    func displayName(for model: AIModel) -> String {
        let key = Self.aliasKey(provider: model.provider, modelID: model.modelID)
        return modelAliases[key] ?? model.displayName
    }

    private func loadModelAliases() {
        guard let data = UserDefaults.standard.data(forKey: modelAliasesKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        modelAliases = decoded
    }

    private func saveModelAliases() {
        if let data = try? JSONEncoder().encode(modelAliases) {
            UserDefaults.standard.set(data, forKey: modelAliasesKey)
        }
    }

    // MARK: - Settings sync

    /// Build a JSON snapshot of the current settings. Used by SettingsSync.
    func snapshotForSync() -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            schemaVersion: AppSettingsSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            alwaysExpandThinking: alwaysExpandThinking,
            defaultPermissionMode: permissionMode,
            defaultEffort: effort,
            environments: environments,
            customProviders: customProviders,
            modelAliases: modelAliases,
            skillsRepoURL: skillsRepoURL,
            skillsRepoBranch: skillsRepoBranch,
            mcpRepoURL: mcpRepoURL,
            mcpRepoBranch: mcpRepoBranch
        )
    }

    /// Apply a snapshot to the live state. The user can review before
    /// accepting on the Settings screen.
    func applySnapshot(_ snapshot: AppSettingsSnapshot) {
        alwaysExpandThinking = snapshot.alwaysExpandThinking
        permissionMode = snapshot.defaultPermissionMode
        effort = snapshot.defaultEffort
        environments = snapshot.environments
        saveEnvironments()
        customProviders = snapshot.customProviders
        saveCustomProviders()
        modelAliases = snapshot.modelAliases
        saveModelAliases()
        skillsRepoURL = snapshot.skillsRepoURL
        skillsRepoBranch = snapshot.skillsRepoBranch
        UserDefaults.standard.set(skillsRepoURL, forKey: skillsRepoKey)
        UserDefaults.standard.set(skillsRepoBranch, forKey: skillsBranchKey)
        mcpRepoURL = snapshot.mcpRepoURL
        mcpRepoBranch = snapshot.mcpRepoBranch
        UserDefaults.standard.set(mcpRepoURL, forKey: mcpRepoKey)
        UserDefaults.standard.set(mcpRepoBranch, forKey: mcpBranchKey)
        if selectedEnvironment == nil { selectedEnvironment = environments.first }
    }
}
