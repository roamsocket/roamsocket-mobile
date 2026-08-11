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
    let browserStore = BrowserStore()

    /// Your GitHub OAuth app client id for Device Flow. Replace before shipping;
    /// can also be provided at runtime via Settings.
    @AppStorage("githubClientID") var githubClientID: String = ""

    // Composer selections (mirror the home screen controls)
    @Published var selectedRepo: GitHubRepo?
    @Published var selectedEnvironment: EnvironmentConfig?
    /// Currently selected chat model. Changing this loads/unloads on-device
    /// Metal models so only the active local model sits in RAM.
    @Published var selectedModel: AIModel? {
        didSet {
            guard oldValue?.id != selectedModel?.id else { return }
            scheduleLocalMetalMemorySync(previous: oldValue, current: selectedModel)
        }
    }
    @Published var effort: Effort = .high
    @Published var permissionMode: PermissionMode = .acceptEdits

    /// True while the selected on-device Metal model is being loaded into RAM.
    @Published var isLoadingLocalMetal = false
    /// 0…1 progress while `isLoadingLocalMetal` is true (disk → RAM / residual hub work).
    @Published var localMetalLoadProgress: Double = 0
    /// Last error from loading the selected local model into memory (if any).
    @Published var localMetalLoadError: String?

    private var localMetalSyncTask: Task<Void, Never>?
    private var localMetalSyncGeneration = 0

    /// Artifact shown in the chat split panel (source chat + scroll target).
    @Published var openArtifact: Artifact?
    /// Scroll the chat transcript to this message after loading (cleared after use).
    @Published var scrollToMessageId: UUID?

    /// Open an artifact: jump to its chat (caller loads history) and show split panel.
    func presentArtifact(_ artifact: Artifact) {
        openArtifact = artifact
        scrollToMessageId = artifact.messageId
    }

    func dismissOpenArtifact() {
        openArtifact = nil
        scrollToMessageId = nil
    }

    /// Metal models installed on the paired desktop (`GET /metal/models`).
    /// Coding pickers show these instead of phone-local Metal weights.
    @Published private(set) var desktopMetalModels: [AIModel] = []
    /// Last error while refreshing desktop Metal models (nil when ok / unpaired).
    @Published private(set) var desktopMetalError: String?
    /// True while fetching desktop Metal inventory.
    @Published private(set) var isLoadingDesktopMetal = false

    /// User-renamed models, keyed by `"provider:modelID"`. Empty entries are
    /// treated as "use the upstream name".
    @Published var modelAliases: [String: String] = [:]

    /// Models the user removed from the picker (keyed like aliases).
    /// Local Metal deletions also erase weights; remote/catalog models are only hidden.
    @Published private(set) var hiddenModelKeys: Set<String> = []

    /// When true, every assistant message expands its Thinking section
    /// by default. When false, thinking collapses behind a one-line preview.
    @AppStorage("alwaysExpandThinking.v1") var alwaysExpandThinking: Bool = false

    /// Allow the assistant to search past chats for relevant details (local).
    @AppStorage("memory.searchChats.v1") var memorySearchChats: Bool = true
    /// Allow generating lasting memory summaries from chats (local).
    @AppStorage("memory.generateFromChats.v1") var memoryGenerateFromChats: Bool = true

    /// App chrome appearance: dark (blue-grey), OLED (true black), or light.
    @AppStorage(AppAppearance.storageKey) var appearanceRaw: String = AppAppearance.default.rawValue

    var appearance: AppAppearance {
        get { AppAppearance.resolve(rawValue: appearanceRaw) }
        set {
            guard newValue.rawValue != appearanceRaw else { return }
            appearanceRaw = newValue.rawValue
            Theme.apply(newValue)
            // @AppStorage does not always publish through ObservableObject;
            // force dependents (and Theme.* readers) to refresh.
            objectWillChange.send()
        }
    }

    /// Branch name prefix for new coding sessions, e.g. `apc/fix-login-a1b2c3d4`.
    @AppStorage("codeBranchPrefix.v1") var codeBranchPrefix: String = "roamsocket"

    /// Active desktop base URL currently used for API/WS (local or tunnel).
    @AppStorage("serverHost.v1") var serverHost: String = ""

    /// LAN address captured at pair time (kept even when active path is tunnel).
    @AppStorage("serverLocalHost.v1") var serverLocalHost: String = ""

    /// Public tunnel URL when the desktop has published one.
    @AppStorage("serverTunnelHost.v1") var serverTunnelHost: String = ""

    /// How the app chooses between LAN and tunnel.
    /// Raw value persisted in AppStorage.
    @AppStorage("serverConnectionPreference.v1") var connectionPreferenceRaw: String = ServerConnectionPreference.smart.rawValue

    /// After a dead tunnel is cleared, request a forced desktop regen once LAN works.
    private var pendingTunnelRegen = false
    private var lastTunnelRegenAt: Date?
    private static let tunnelRegenCooldownSeconds: TimeInterval = 60

    /// Coalesces concurrent reconnect attempts so `isReconnecting` can't flip
    /// false while a later attempt is still in flight, and so Code home / launch
    /// / Settings don't race `activateEndpoint`.
    private var reconnectTask: Task<ServerReconnectOutcome, Never>?

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
    /// True when the last reconnect failed because the desktop rejected the token.
    @Published private(set) var needsServerRePair = false
    /// Live reachability of the paired desktop (used by Devices status dots).
    @Published private(set) var desktopReachability: DesktopReachability = .unpaired

    /// Result of an interactive reconnect attempt (Devices tab, recovery sheet).
    enum ServerReconnectOutcome: Equatable {
        case connected
        case needsRePair
        case unreachable
        case unpaired
    }

    /// Whether the paired desktop is reachable right now.
    enum DesktopReachability: Equatable {
        case unpaired
        case connecting
        case connected
        case unreachable

        var label: String {
            switch self {
            case .unpaired: return "Not paired"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .unreachable: return "Unable to connect"
            }
        }
    }

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
        desktopReachability = .connected
        // Keep “refreshing tunnel…” copy when we just fell back from a dead tunnel.
        if !pendingTunnelRegen {
            reconnectMessage = nil
        }
        // After tunnel → local fallback, ask the desktop for a fresh public URL.
        if pendingTunnelRegen, Self.connectionPath(for: endpoint) == .local {
            scheduleTunnelRegenerationIfNeeded()
        }
    }

    /// Session/UI hooks for the Devices status dot while a socket is opening.
    func markDesktopConnecting() {
        guard serverToken != nil else {
            desktopReachability = .unpaired
            return
        }
        desktopReachability = .connecting
    }

    func markDesktopUnreachable(_ message: String? = nil) {
        guard serverToken != nil else {
            desktopReachability = .unpaired
            return
        }
        desktopReachability = .unreachable
        if let message, !message.isEmpty {
            reconnectMessage = message
        }
    }

    // Chat state (per-chat toggles live on `ChatViewModel`; nothing here yet.)

    private let environmentsKey = "environments.v1"
    private let skillsRepoKey = "skillsRepoURL.v1"
    private let skillsBranchKey = "skillsRepoBranch.v1"
    private let mcpRepoKey = "mcpRepoURL.v1"
    private let mcpBranchKey = "mcpRepoBranch.v1"
    private let customProvidersKey = "customProviders.v1"
    private let modelAliasesKey = "modelAliases.v1"
    private let hiddenModelsKey = "hiddenModels.v1"
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
        loadHiddenModels()
        seedDefaultEnvironmentIfNeeded()
        restorePairingFromDisk()
        Task { await attemptServerReconnect() }
        // Official + user marketplaces: connectors, skill listings, plugins, Metal.
        Task { await MarketplaceStore.shared.refresh() }
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
        desktopReachability = .connected
        reconnectMessage = nil
    }

    /// Remember the desktop's public tunnel URL while keeping the LAN address.
    /// Activates tunnel when preference is Smart or Always tunnel.
    /// When `requireReachable` is true, runs a health check before switching
    /// the active path (avoids re-applying a dead tunnel after LAN fallback).
    @discardableResult
    func applyRemoteEndpoint(urlString: String, requireReachable: Bool = false) async -> Bool {
        let trimmed = normalizeHostString(urlString)
        guard !trimmed.isEmpty, let endpoint = ServerClient.Endpoint(host: trimmed) else {
            return false
        }
        guard serverToken != nil, !(serverToken ?? "").isEmpty else { return false }

        if requireReachable {
            let ok = await isEndpointReachable(endpoint)
            if !ok {
                reconnectMessage = "New tunnel not reachable yet — staying on local."
                return false
            }
        }

        let previousTunnel = normalizeHostString(serverTunnelHost)
        serverTunnelHost = trimmed
        secrets.set(serverToken, for: SecretKey.serverToken(trimmed))
        pendingTunnelRegen = false

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

    /// Drop a public tunnel URL that failed health/connect so we stop preferring it.
    /// Sets `pendingTunnelRegen` so the next successful LAN path can request a fresh tunnel.
    func clearTunnelEndpoint(requestRegen: Bool = true) {
        let previous = normalizeHostString(serverTunnelHost)
        guard !previous.isEmpty else {
            if requestRegen { pendingTunnelRegen = true }
            return
        }

        // If the active path is the dead tunnel, switch to local first when possible.
        let activeIsTunnel = serverEndpoint.map { Self.connectionPath(for: $0) == .tunnel } ?? false
            || normalizeHostString(serverHost).caseInsensitiveCompare(previous) == .orderedSame
        if activeIsTunnel, let local = localEndpoint {
            activateEndpoint(local)
        }

        secrets.set(nil, for: SecretKey.serverToken(previous))
        if let token = serverToken, !token.isEmpty {
            if !serverLocalHost.isEmpty {
                secrets.set(token, for: SecretKey.serverToken(serverLocalHost))
            }
            let activeHost = normalizeHostString(serverHost)
            if !activeHost.isEmpty, activeHost.caseInsensitiveCompare(previous) != .orderedSame {
                secrets.set(token, for: SecretKey.serverToken(activeHost))
            }
        }
        serverTunnelHost = ""
        if requestRegen { pendingTunnelRegen = true }
        objectWillChange.send()
    }

    /// After a tunnel failure: clear the dead URL, stay/use local, ask desktop for a new tunnel.
    func invalidateTunnelAndRegenerate(reason: String? = nil) {
        clearTunnelEndpoint(requestRegen: true)
        reconnectMessage = reason ?? "Tunnel unreachable — using local. Refreshing tunnel…"
        scheduleTunnelRegenerationIfNeeded()
    }

    /// Cooldown-gated force-regen over the LAN endpoint (background recovery).
    func scheduleTunnelRegenerationIfNeeded() {
        guard pendingTunnelRegen || tunnelEndpoint == nil else { return }
        if let last = lastTunnelRegenAt,
           Date().timeIntervalSince(last) < Self.tunnelRegenCooldownSeconds {
            return
        }
        lastTunnelRegenAt = Date()
        Task { _ = await ensureTunnelFromLocal(force: true) }
    }

    /**
     Ask the desktop (over LAN) for a public tunnel URL and apply it if healthy.
     - `force: false` — reuse an existing desktop tunnel or start one if missing.
     - `force: true` — tear down and mint a new public URL (dead-tunnel recovery).
     Returns true when a reachable tunnel is now active (or stored for Always local).
     */
    @discardableResult
    func ensureTunnelFromLocal(force: Bool) async -> Bool {
        guard let token = serverToken, !token.isEmpty else {
            pendingTunnelRegen = false
            return false
        }
        let local = localEndpoint
            ?? serverEndpoint.flatMap { Self.connectionPath(for: $0) == .local ? $0 : nil }
        guard let local else {
            reconnectMessage = "No local address to open a tunnel from — pair on the same Wi‑Fi first."
            pendingTunnelRegen = false
            return false
        }

        // Need a LAN path to talk to the desktop while the public URL is missing/dead.
        if let active = serverEndpoint, Self.connectionPath(for: active) != .local {
            activateEndpoint(local)
        } else if serverEndpoint == nil {
            activateEndpoint(local)
        }

        reconnectMessage = force
            ? "Refreshing secure tunnel…"
            : "Opening secure tunnel…"
        desktopReachability = .connecting
        lastTunnelRegenAt = Date()

        do {
            let client = ServerClient()
            let result = try await client.requestRemoteEndpoint(
                endpoint: local,
                token: token,
                force: force,
                timeoutSeconds: 50
            )
            if await applyRemoteEndpoint(urlString: result.url, requireReachable: true) {
                let provider = result.provider.map { " via \($0)" } ?? ""
                reconnectMessage = "Secure tunnel ready\(provider)."
                desktopReachability = .connected
                return true
            }
            pendingTunnelRegen = false
            // Preference may still want tunnel; keep LAN usable.
            if connectionPreference == .alwaysTunnel {
                reconnectMessage = "Tunnel URL not reachable yet — staying on local."
            } else {
                reconnectMessage = "Using local. New tunnel not reachable yet."
            }
            desktopReachability = .connected
            return false
        } catch {
            pendingTunnelRegen = false
            if connectionPreference == .alwaysTunnel {
                reconnectMessage = "Could not open tunnel: \(error.localizedDescription)"
                // Stay on local if we have it so the session still works.
                if localEndpoint != nil || Self.connectionPath(for: local) == .local {
                    activateEndpoint(local)
                    desktopReachability = .connected
                } else {
                    desktopReachability = .unreachable
                }
            } else {
                reconnectMessage = "Using local. Tunnel refresh failed: \(error.localizedDescription)"
                desktopReachability = .connected
            }
            return false
        }
    }

    /// Background recovery entry point (forced restart of a dead tunnel).
    func regenerateTunnelFromServer() async {
        _ = await ensureTunnelFromLocal(force: true)
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
            if await applyRemoteEndpoint(urlString: result.url, requireReachable: true) {
                let provider = result.provider.map { " via \($0)" } ?? ""
                switch connectionPreference {
                case .alwaysLocal:
                    return "Paired on LAN. Tunnel ready\(provider) (preference is Local)."
                case .alwaysTunnel, .smart:
                    return "Paired. Secure tunnel ready\(provider)."
                }
            }
            return "Paired on LAN. Tunnel URL received but not reachable yet."
        } catch {
            return "Paired on LAN. Tunnel unavailable: \(error.localizedDescription)"
        }
    }

    /// Change connection preference and re-resolve active endpoint.
    /// When switching to Always tunnel with no (or a dead) URL, opens a tunnel
    /// over the LAN automatically instead of only showing an error.
    func setConnectionPreference(_ preference: ServerConnectionPreference) async {
        connectionPreference = preference
        isReconnecting = true
        desktopReachability = .connecting
        defer { isReconnecting = false }
        await applyConnectionPreference(healthCheck: true)
    }

    /**
     Pick the active endpoint from local/tunnel slots according to preference.
     Smart mode prefers tunnel when its health check passes, otherwise local.
     Always tunnel will request a public URL from the desktop when missing.
     */
    func applyConnectionPreference(healthCheck: Bool = true) async {
        guard serverToken != nil, !(serverToken ?? "").isEmpty else {
            desktopReachability = .unpaired
            return
        }

        // Seed slots from the current active host if they were never split.
        if localEndpoint == nil, tunnelEndpoint == nil, let active = serverEndpoint {
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
                    if healthCheck { desktopReachability = .connected }
                    return
                }
                reconnectMessage = "Local desktop not reachable."
                if healthCheck { desktopReachability = .unreachable }
            } else {
                reconnectMessage = "No local address saved — pair on the same Wi‑Fi first."
                if healthCheck { desktopReachability = .unreachable }
            }

        case .alwaysTunnel:
            var hadDeadTunnel = false
            if let tunnelNow {
                let ok = healthCheck ? await isEndpointReachable(tunnelNow) : true
                if ok {
                    activateEndpoint(tunnelNow)
                    reconnectMessage = nil
                    if healthCheck { desktopReachability = .connected }
                    return
                }
                // Dead tunnel: drop it so we mint a fresh public URL over LAN.
                if healthCheck {
                    clearTunnelEndpoint(requestRegen: false)
                    hadDeadTunnel = true
                }
            }

            // No tunnel URL (or just cleared a dead one) — open one via LAN.
            guard healthCheck else {
                reconnectMessage = "No tunnel URL yet."
                return
            }
            guard let localNow, await isEndpointReachable(localNow) else {
                reconnectMessage = localNow == nil
                    ? "No local address to open a tunnel from — pair on the same Wi‑Fi first."
                    : "Desktop not reachable on local — can't open a tunnel."
                desktopReachability = .unreachable
                return
            }
            activateEndpoint(localNow)
            // Force-restart only when replacing a dead URL; otherwise reuse/start on desktop.
            _ = await ensureTunnelFromLocal(force: hadDeadTunnel)

        case .smart:
            // Prefer tunnel, fall back to local; drop dead tunnels and regen.
            var tunnelFailed = false
            if let tunnelNow {
                let ok = healthCheck ? await isEndpointReachable(tunnelNow) : true
                if ok {
                    activateEndpoint(tunnelNow)
                    reconnectMessage = nil
                    if healthCheck { desktopReachability = .connected }
                    return
                }
                tunnelFailed = healthCheck
                if tunnelFailed {
                    clearTunnelEndpoint(requestRegen: true)
                }
            }
            if let localNow {
                let ok = healthCheck ? await isEndpointReachable(localNow) : true
                if ok {
                    activateEndpoint(localNow)
                    if tunnelFailed {
                        reconnectMessage = "Tunnel unreachable — using local. Refreshing tunnel…"
                        scheduleTunnelRegenerationIfNeeded()
                    } else {
                        reconnectMessage = nil
                    }
                    if healthCheck { desktopReachability = .connected }
                    return
                }
            }
            // Last resort: still point at preferred path so UI shows intent.
            if let tunnelNow = tunnelEndpoint {
                activateEndpoint(tunnelNow)
                reconnectMessage = "Desktop not reachable on tunnel or local."
            } else if let localNow {
                activateEndpoint(localNow)
                reconnectMessage = "Desktop not reachable."
            }
            if healthCheck { desktopReachability = .unreachable }
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
        desktopReachability = .unpaired
        isReconnecting = false
        reconnectMessage = nil
        needsServerRePair = false
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
        // Mark connecting until the launch health check finishes.
        desktopReachability = .connecting
    }

    /// Health-check preferred endpoints and settle on the best path.
    /// Concurrent callers join the in-flight attempt instead of racing state.
    @discardableResult
    func attemptServerReconnect() async -> ServerReconnectOutcome {
        if let existing = reconnectTask {
            return await existing.value
        }
        let task = Task { @MainActor in
            await self.performServerReconnect()
        }
        reconnectTask = task
        let result = await task.value
        if reconnectTask == task {
            reconnectTask = nil
        }
        return result
    }

    /**
     Point the phone at a specific LAN address (from Bonjour rescan or typed IP),
     keep the saved token, and try to reconnect. Use when the desktop IP changed
     or discovery found a host the user wants to try.

     Only commits the new address after HTTP health + WebSocket succeed, so a
     mistyped IP cannot clobber a working tunnel/local path.
     */
    @discardableResult
    func reconnectToEndpoint(_ endpoint: ServerClient.Endpoint) async -> ServerReconnectOutcome {
        // Drain any in-flight reconnect before starting a host-specific attempt.
        // Loop so two concurrent callers don't both assign reconnectTask.
        while let existing = reconnectTask {
            _ = await existing.value
        }
        let task = Task { @MainActor in
            await self.performReconnectToEndpoint(endpoint)
        }
        reconnectTask = task
        let result = await task.value
        if reconnectTask == task {
            reconnectTask = nil
        }
        return result
    }

    private func performServerReconnect() async -> ServerReconnectOutcome {
        guard serverToken != nil, !(serverToken ?? "").isEmpty else {
            reconnectMessage = nil
            needsServerRePair = false
            desktopReachability = .unpaired
            return .unpaired
        }
        isReconnecting = true
        desktopReachability = .connecting
        needsServerRePair = false
        defer { isReconnecting = false }

        await applyConnectionPreference(healthCheck: true)

        guard let endpoint = serverEndpoint, let token = serverToken else {
            reconnectMessage = "Not paired."
            desktopReachability = .unpaired
            return .unpaired
        }

        // If HTTP health already failed, don't try a WebSocket probe.
        if desktopReachability == .unreachable {
            return .unreachable
        }

        // Validate token with a short-lived WebSocket on the chosen path.
        do {
            if let name = await fetchServerName(endpoint: endpoint) {
                // Pairing may have been cleared while the probe was in flight.
                guard serverToken != nil else {
                    desktopReachability = .unpaired
                    return .unpaired
                }
                serverName = name
                UserDefaults.standard.set(name, forKey: serverNameKey)
            }
            let client = ServerClient()
            let stream = try await client.connect(endpoint: endpoint, token: token)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await client.disconnect()
            _ = stream
            guard serverToken != nil else {
                desktopReachability = .unpaired
                return .unpaired
            }
            // Keep “refreshing tunnel…” copy when we just fell back from a dead tunnel.
            if !pendingTunnelRegen {
                reconnectMessage = nil
            }
            needsServerRePair = false
            desktopReachability = .connected
            return .connected
        } catch {
            guard serverToken != nil else {
                desktopReachability = .unpaired
                return .unpaired
            }
            // If smart/local failed the WS step, try the other path once.
            if connectionPreference == .smart {
                return await tryAlternatePath(after: endpoint, error: error)
            }
            return markReconnectFailure(error)
        }
    }

    private func performReconnectToEndpoint(_ endpoint: ServerClient.Endpoint) async -> ServerReconnectOutcome {
        guard let token = serverToken, !token.isEmpty else {
            reconnectMessage = "Not paired."
            needsServerRePair = false
            desktopReachability = .unpaired
            return .unpaired
        }

        let hostLabel = endpoint.baseURL.host ?? endpoint.baseURL.absoluteString
        let previousEndpoint = serverEndpoint

        isReconnecting = true
        desktopReachability = .connecting
        needsServerRePair = false
        defer { isReconnecting = false }

        guard await isEndpointReachable(endpoint) else {
            reconnectMessage = "Desktop not reachable at \(hostLabel)."
            // Don't clobber a still-working active path with a bad typed IP.
            if let previous = previousEndpoint, await isEndpointReachable(previous) {
                desktopReachability = .connected
                reconnectMessage = "Couldn't reach \(hostLabel). Previous connection still works."
            } else {
                desktopReachability = .unreachable
            }
            return .unreachable
        }

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
            guard serverToken != nil else {
                desktopReachability = .unpaired
                return .unpaired
            }
            // Commit only after health + authenticated WS succeed.
            recordEndpoint(endpoint)
            activateEndpoint(endpoint)
            reconnectMessage = nil
            needsServerRePair = false
            desktopReachability = .connected
            return .connected
        } catch {
            guard serverToken != nil else {
                desktopReachability = .unpaired
                return .unpaired
            }
            if Self.isUnauthorizedError(error) {
                return markReconnectFailure(error)
            }
            // Network/WS failure on this address only — restore prior status when possible.
            reconnectMessage = "Couldn't connect to \(hostLabel): \(error.localizedDescription)"
            if let previous = previousEndpoint, await isEndpointReachable(previous) {
                desktopReachability = .connected
            } else {
                desktopReachability = .unreachable
            }
            return .unreachable
        }
    }

    @discardableResult
    private func tryAlternatePath(after failed: ServerClient.Endpoint, error: Error) async -> ServerReconnectOutcome {
        let failedPath = Self.connectionPath(for: failed)
        if failedPath == .tunnel {
            // Forget the dead public URL before trying LAN so we don't loop on it.
            clearTunnelEndpoint(requestRegen: true)
        }
        let alternate: ServerClient.Endpoint? = {
            switch failedPath {
            case .tunnel: return localEndpoint
            case .local: return tunnelEndpoint
            case .offline: return localEndpoint ?? tunnelEndpoint
            }
        }()
        guard let alternate, let token = serverToken else {
            return markReconnectFailure(error)
        }
        guard await isEndpointReachable(alternate) else {
            return markReconnectFailure(error)
        }
        activateEndpoint(alternate)
        do {
            let client = ServerClient()
            let stream = try await client.connect(endpoint: alternate, token: token)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await client.disconnect()
            _ = stream
            if failedPath == .tunnel {
                reconnectMessage = "Tunnel failed — switched to local. Refreshing tunnel…"
                desktopReachability = .connected
                scheduleTunnelRegenerationIfNeeded()
            } else {
                reconnectMessage = "Local failed — switched to tunnel."
                desktopReachability = .connected
            }
            needsServerRePair = false
            return .connected
        } catch {
            return markReconnectFailure(error)
        }
    }

    @discardableResult
    private func markReconnectFailure(_ error: Error) -> ServerReconnectOutcome {
        reconnectMessage = Self.reconnectFailureMessage(error)
        desktopReachability = .unreachable
        if Self.isUnauthorizedError(error) {
            needsServerRePair = true
            return .needsRePair
        }
        needsServerRePair = false
        return .unreachable
    }

    /// Prefer a pairing-focused message when the desktop rejected the saved token.
    private static func reconnectFailureMessage(_ error: Error) -> String {
        if isUnauthorizedError(error) {
            return "Pairing expired — open Desktop server and enter a new pairing code."
        }
        return "Could not reconnect: \(error.localizedDescription)"
    }

    static func isUnauthorizedError(_ error: Error) -> Bool {
        isUnauthorizedError(error.localizedDescription)
    }

    static func isUnauthorizedError(_ detail: String) -> Bool {
        detail.localizedCaseInsensitiveContains("unauthorized")
            || detail.localizedCaseInsensitiveContains("re-pair")
            || detail.localizedCaseInsensitiveContains("token expired")
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
        style: CustomProviderStyle = .openAI,
        supportsVision: Bool = false
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
            style: style,
            supportsVision: supportsVision
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
        apiKey: String?,
        supportsVision: Bool? = nil
    ) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = Self.normalizeBaseURL(baseURL)
        guard !trimmedLabel.isEmpty, !normalizedURL.isEmpty else { return }
        guard let idx = customProviders.firstIndex(where: { $0.id == provider.id }) else { return }
        customProviders[idx].label = trimmedLabel
        customProviders[idx].baseURL = normalizedURL
        customProviders[idx].style = style
        if let supportsVision {
            customProviders[idx].supportsVision = supportsVision
        }
        saveCustomProviders()
        if let apiKey {
            setAPIKey(apiKey, for: provider.providerID)
        }
    }

    /// Vision eligibility including custom-provider “supports vision” toggles.
    func modelSupportsVision(_ model: AIModel) -> Bool {
        let flagged = customProvider(for: model.provider)?.supportsVision == true
        return VisionCapability.supportsVision(model, providerMarkedVisionCapable: flagged)
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
        // On-device chat providers (Metal, Apple Intelligence) never need a cloud key.
        if !provider.requiresAPIKey { return "local" }
        if case .custom = provider, apiStyle(for: provider) == .openAI {
            return "local"
        }
        return ""
    }

    func setAPIKey(_ key: String, for provider: ProviderID) {
        secrets.set(key.isEmpty ? nil : key, for: SecretKey.providerAPIKey(provider))
    }

    // MARK: Voice-only API keys (TTS providers that are not chat hosts)

    /// Key for a voice-only provider (e.g. `elevenlabs`). Stored separately from chat keys.
    func voiceAPIKey(for id: String) -> String {
        secrets.get(SecretKey.voiceAPIKey(id)) ?? ""
    }

    func setVoiceAPIKey(_ key: String, for id: String) {
        secrets.set(key.isEmpty ? nil : key, for: SecretKey.voiceAPIKey(id))
    }

    var githubToken: String? {
        get { secrets.get(SecretKey.githubToken) }
        set { secrets.set(newValue, for: SecretKey.githubToken) }
    }

    var allModels: [AIModel] {
        providerResults.flatMap(\.models).filter { !isModelHidden($0) }
    }

    /// Models for a provider result after applying the user's hide list.
    func visibleModels(in result: ModelCatalog.ProviderResult) -> [AIModel] {
        result.models.filter { !isModelHidden($0) }
    }

    func isModelHidden(_ model: AIModel) -> Bool {
        hiddenModelKeys.contains(Self.aliasKey(provider: model.provider, modelID: model.modelID))
    }

    /// Hidden models across every catalog result (and desktop Metal inventory).
    /// Used by the picker's "Hidden models" section so users can unhide one at a time.
    var hiddenModels: [AIModel] {
        var all = providerResults.flatMap(\.models)
        if !desktopMetalModels.isEmpty { all += desktopMetalModels }
        return all.filter { isModelHidden($0) }
    }

    /// Toggle a model's visibility in the picker. Hiding keeps the model and any
    /// alias intact (unlike swipe Delete) so it can be brought back with one tap.
    func toggleModelHidden(_ model: AIModel) {
        let key = Self.aliasKey(provider: model.provider, modelID: model.modelID)
        if hiddenModelKeys.contains(key) {
            hiddenModelKeys.remove(key)
        } else {
            hiddenModelKeys.insert(key)
            if selectedModel?.id == model.id {
                selectedModel = allModels.first
            }
        }
        saveHiddenModels()
        objectWillChange.send()
    }

    /// Hide a catalog model from the picker (or delete on-device Metal weights).
    /// Returns a short status line for the UI, or throws for Metal failures.
    @discardableResult
    func removeModelFromPicker(_ model: AIModel) async throws -> String {
        if model.provider == .localMetal {
            LocalMetalBootstrap.ensureRegistered()
            guard let engine = LocalMetalRuntime.engine else {
                throw ProviderError.transport("Metal runtime is not linked.")
            }
            try await engine.deleteModel(modelID: model.modelID)
            await LocalMetalModelStore.shared.markDeleted(modelID: model.modelID)
            let removedID = model.id
            if selectedModel?.id == removedID {
                selectedModel = nil
            }
            await refreshModels()
            if selectedModel == nil {
                selectedModel = allModels.first
            }
            return "Deleted on-device model from disk."
        }

        hideModelKey(for: model)
        modelAliases.removeValue(forKey: Self.aliasKey(provider: model.provider, modelID: model.modelID))
        saveModelAliases()
        if selectedModel?.id == model.id {
            selectedModel = allModels.first
        }
        objectWillChange.send()
        return "Removed from model list."
    }

    private func hideModelKey(for model: AIModel) {
        hiddenModelKeys.insert(Self.aliasKey(provider: model.provider, modelID: model.modelID))
        saveHiddenModels()
    }

    /// True when the user has swipe-hidden catalog models (not disk-deleted Metal).
    var hasHiddenModels: Bool { !hiddenModelKeys.isEmpty }

    /// Restore all swipe-hidden remote/catalog models to the picker.
    func restoreHiddenModels() {
        guard !hiddenModelKeys.isEmpty else { return }
        hiddenModelKeys = []
        saveHiddenModels()
        objectWillChange.send()
    }

    private func loadHiddenModels() {
        guard let data = UserDefaults.standard.data(forKey: hiddenModelsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        hiddenModelKeys = Set(decoded)
    }

    private func saveHiddenModels() {
        let list = Array(hiddenModelKeys).sorted()
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: hiddenModelsKey)
        }
    }

    // MARK: Models

    func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        var keys: [ProviderID: String] = [:]
        var customBaseURLs: [ProviderID: URL] = [:]
        var styles: [ProviderID: CustomProviderStyle] = [:]
        for provider in ProviderID.allBuiltInCases {
            if !provider.requiresAPIKey {
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
        // When still listed, refresh metadata (friendly display names, etc.).
        if let selected = selectedModel {
            if let updated = allModels.first(where: { $0.id == selected.id }) {
                let canCall = !resolvedAPIKey(for: selected.provider).isEmpty
                if canCall {
                    if updated.displayName != selected.displayName
                        || updated.contextWindow != selected.contextWindow {
                        selectedModel = updated
                    }
                } else {
                    selectedModel = allModels.first
                }
            } else {
                selectedModel = allModels.first
            }
        } else {
            selectedModel = allModels.first
        }
        // Ensure RAM matches selection after catalog refresh (e.g. new download).
        await ensureSelectedLocalMetalLoaded()
    }

    // MARK: Local Metal RAM policy

    /// Only the **selected** on-device model may stay in memory. Downloads leave
    /// weights on disk; picking another model unloads the previous one.
    func scheduleLocalMetalMemorySync(previous: AIModel?, current: AIModel?) {
        localMetalSyncGeneration += 1
        let generation = localMetalSyncGeneration
        localMetalSyncTask?.cancel()
        localMetalSyncTask = Task { @MainActor in
            await syncLocalMetalMemory(
                previous: previous,
                current: current,
                generation: generation
            )
        }
    }

    /// Awaitable re-sync for the current selection (call after a download finishes).
    func ensureSelectedLocalMetalLoaded() async {
        scheduleLocalMetalMemorySync(previous: nil, current: selectedModel)
        await localMetalSyncTask?.value
    }

    private func syncLocalMetalMemory(
        previous: AIModel?,
        current: AIModel?,
        generation: Int
    ) async {
        LocalMetalBootstrap.ensureRegistered()
        guard let engine = LocalMetalRuntime.engine else {
            clearLocalMetalLoadingState()
            return
        }
        guard !Task.isCancelled, generation == localMetalSyncGeneration else { return }

        // Desktop-only Metal selections run on the paired server — do not try
        // to load those weights into the phone's Metal runtime.
        if let current, current.provider == .localMetal {
            let phoneModels = await LocalMetalModelStore.shared.listModels()
            let onPhone = phoneModels.contains { $0.modelID == current.modelID }
            if !onPhone {
                if generation == localMetalSyncGeneration {
                    await engine.unloadAllFromMemory()
                    clearLocalMetalLoadingState()
                }
                return
            }
        }

        let keepID: String? = (current?.provider == .localMetal) ? current?.modelID : nil

        // Unload everything that shouldn't be resident.
        let loaded = await engine.loadedModelIDs()
        for id in loaded where id != keepID {
            await engine.unloadFromMemory(modelID: id)
        }
        if keepID == nil {
            if !loaded.isEmpty {
                await engine.unloadAllFromMemory()
            }
            if generation == localMetalSyncGeneration {
                clearLocalMetalLoadingState()
                localMetalLoadError = nil
            }
            return
        }

        guard let modelID = keepID else { return }
        if await engine.isLoadedInMemory(modelID: modelID) {
            if generation == localMetalSyncGeneration {
                clearLocalMetalLoadingState()
                localMetalLoadError = nil
            }
            return
        }

        guard !Task.isCancelled, generation == localMetalSyncGeneration else { return }
        isLoadingLocalMetal = true
        localMetalLoadProgress = 0
        localMetalLoadError = nil
        defer {
            if generation == localMetalSyncGeneration {
                clearLocalMetalLoadingState()
            }
        }

        do {
            try await engine.loadIntoMemory(modelID: modelID) { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    // Drop stale callbacks after cancel, model switch, or load finished.
                    guard generation == self.localMetalSyncGeneration,
                          self.isLoadingLocalMetal
                    else { return }
                    // Monotonic so a brief 0-report doesn't rewind the bar.
                    let next = min(1, max(0, fraction))
                    if next >= self.localMetalLoadProgress {
                        self.localMetalLoadProgress = next
                    }
                }
            }
            // If the user picked another model mid-load, drop this one.
            guard !Task.isCancelled, generation == localMetalSyncGeneration else {
                await engine.unloadFromMemory(modelID: modelID)
                return
            }
            localMetalLoadProgress = 1
            // Belt-and-suspenders: never keep more than one local model in RAM.
            for id in await engine.loadedModelIDs() where id != modelID {
                await engine.unloadFromMemory(modelID: id)
            }
            _ = previous // reserved for future telemetry
        } catch is CancellationError {
            await engine.unloadFromMemory(modelID: modelID)
        } catch {
            await engine.unloadFromMemory(modelID: modelID)
            if generation == localMetalSyncGeneration {
                localMetalLoadError =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func clearLocalMetalLoadingState() {
        isLoadingLocalMetal = false
        localMetalLoadProgress = 0
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

    // MARK: Desktop Metal (coding)

    /// Refresh installed Metal models on the paired desktop. Safe no-op when unpaired.
    func refreshDesktopMetalModels() async {
        guard let endpoint = serverEndpoint, let token = serverToken, !token.isEmpty else {
            desktopMetalModels = []
            desktopMetalError = nil
            isLoadingDesktopMetal = false
            return
        }
        isLoadingDesktopMetal = true
        defer { isLoadingDesktopMetal = false }
        do {
            let response = try await serverClient.listDesktopMetalModels(
                endpoint: endpoint,
                token: token
            )
            desktopMetalModels = response.models.map { $0.asAIModel() }
            if response.models.isEmpty {
                desktopMetalError = response.runtimeReady
                    ? nil
                    : response.detail
            } else if !response.runtimeReady {
                // Models are listed even when mlx-lm is missing so the user can
                // see inventory; surface runtime readiness as a soft warning.
                desktopMetalError = response.detail
            } else {
                desktopMetalError = nil
            }
        } catch {
            desktopMetalModels = []
            desktopMetalError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Whether this model is installed on the paired desktop Metal store.
    func isDesktopMetalModel(_ model: AIModel) -> Bool {
        model.provider == .localMetal
            && desktopMetalModels.contains { $0.modelID == model.modelID }
    }

    // MARK: Model selection for a session

    /// Build the `ModelSelection` the server needs, pulling the key from Keychain.
    /// Phone-only chat providers are excluded; desktop Metal is allowed when
    /// the hub id is (or was) listed from the paired server.
    func modelSelectionForSession() -> ModelSelection? {
        guard let model = selectedModel else { return nil }
        guard model.provider.supportsCodingAgent else { return nil }
        // Metal coding only when the desktop has that model (or we previously
        // selected it from the desktop list — still send hub id to the server).
        if model.provider == .localMetal {
            // Prefer explicit desktop inventory; still allow if the selection
            // already carries the desktop display suffix from a prior fetch.
            let onDesktop = isDesktopMetalModel(model)
                || model.displayName.contains("· Desktop")
            guard onDesktop else { return nil }
        }
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
    /// Local Metal models always resolve to a friendly name (not a hub code id).
    func displayName(for model: AIModel) -> String {
        let key = Self.aliasKey(provider: model.provider, modelID: model.modelID)
        if let alias = modelAliases[key], !alias.isEmpty {
            return alias
        }
        if model.provider == .localMetal {
            let pretty = LocalMetalCatalog.displayName(for: model.modelID)
            // Picker / composer show the Metal suffix for on-device models.
            if model.displayName.hasSuffix(" · Metal") || model.displayName.hasSuffix("· Metal") {
                return pretty + " · Metal"
            }
            return pretty
        }
        return model.displayName
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
            hiddenModels: Array(hiddenModelKeys).sorted(),
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
        hiddenModelKeys = Set(snapshot.hiddenModels)
        saveHiddenModels()
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
