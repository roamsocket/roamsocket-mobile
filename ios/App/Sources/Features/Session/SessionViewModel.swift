import Foundation
import SwiftUI
import Combine
import AnyProvCore

/// Drives one coding session: connects to the server, streams protocol events
/// into a transcript, handles permission prompts, and creates the PR.
@MainActor
final class SessionViewModel: ObservableObject {
    enum Item: Identifiable {
        case user(id: UUID, text: String)
        case assistant(id: UUID, text: String)
        case tool(id: String, tool: String, summary: String, ok: Bool?, output: String?)
        case diff(id: UUID, path: String, patch: String, added: Int, removed: Int)
        case notice(id: UUID, text: String)

        var id: String {
            switch self {
            case let .user(id, _): return "u-\(id)"
            case let .assistant(id, _): return "a-\(id)"
            case let .tool(id, _, _, _, _): return "t-\(id)"
            case let .diff(id, _, _, _, _): return "d-\(id)"
            case let .notice(id, _): return "n-\(id)"
            }
        }
    }

    struct PendingPermission: Identifiable {
        let id: String  // requestId
        let tool: String
        let summary: String
    }

    @Published var items: [Item] = []
    /// True while the agent is mid-turn (tools / streaming). Not used for WS connect.
    @Published var isRunning = false
    /// True after `session_created` — safe to send user messages.
    @Published private(set) var isSessionReady = false
    @Published var pendingPermission: PendingPermission?
    @Published var prURL: URL?
    /// Wire protocol session id — used by SSH / Files / ports against the desktop.
    @Published private(set) var sessionID: String
    @Published var connectionError: String?
    /// Short status under the env pill (Connecting… / Disconnected / nil when healthy).
    @Published var connectionStatusLine: String? = "Connecting…"
    /// Text the user typed while the agent is running. Sent when the
    /// current turn finishes.
    @Published var queuedMessage: String = ""
    /// True while a git_publish request is in flight.
    @Published var isPublishing = false
    /// Suggested / editable commit message for the git sheet.
    @Published var commitMessage: String = ""
    @Published var isGeneratingCommitMessage = false
    /// Listening ports on the desktop (for preview / browser).
    @Published var openPorts: [ServerMessage.PortEntryPayload] = []
    /// Best guess at the project's web server port, if any.
    @Published var primaryWebPort: Int?
    @Published var webPreviewURL: URL?

    /// Composer accepts text once the desktop session exists.
    /// Soft notices (skills sync, project env warnings) must not block input.
    var canAcceptInput: Bool { isSessionReady }

    private let config: SessionConfig
    private let client: ServerClient
    private let catalog = ModelCatalog()
    private var streamTask: Task<Void, Never>?
    private var portsTask: Task<Void, Never>?
    private var transcriptSaveTask: Task<Void, Never>?
    /// FIFO of follow-ups typed while the agent was busy (or before ready).
    private var pendingOutgoing: [String] = []
    weak var state: AppState?

    /// Common dev-server ports preferred when choosing a browser target.
    private static let preferredWebPorts: [Int] = [
        3000, 5173, 5174, 4173, 8080, 8000, 4200, 5000, 4321, 1234, 3001, 8081,
    ]

    init(config: SessionConfig, client: ServerClient) {
        self.config = config
        self.client = client
        self.sessionID = config.wireSessionId
        if let pr = config.prURL { self.prURL = URL(string: pr) }
    }

    /// Hydrate transcript from the persisted session row (archives / re-open).
    func loadPersistedTranscript(from store: CodeSessionStore) {
        guard let id = config.localSessionId,
              let session = store.session(id: id),
              !session.transcript.isEmpty,
              items.isEmpty
        else { return }
        items = session.transcript.map { Self.item(from: $0) }
    }

    /// Persist the live transcript onto the Code session row (for archives).
    func persistTranscript() {
        guard let id = config.localSessionId else { return }
        let lines = items.map { Self.line(from: $0) }
        state?.codeSessionStore.saveTranscript(id, lines: lines)
    }

    private func scheduleTranscriptSave() {
        transcriptSaveTask?.cancel()
        transcriptSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            persistTranscript()
        }
    }

    private static func line(from item: Item) -> SessionTranscriptLine {
        switch item {
        case let .user(id, text):
            return SessionTranscriptLine(id: "u-\(id.uuidString)", kind: .user, text: text)
        case let .assistant(id, text):
            return SessionTranscriptLine(id: "a-\(id.uuidString)", kind: .assistant, text: text)
        case let .tool(id, tool, summary, ok, output):
            return SessionTranscriptLine(
                id: "t-\(id)",
                kind: .tool,
                text: [summary, output].compactMap { $0 }.joined(separator: "\n"),
                tool: tool,
                ok: ok
            )
        case let .diff(id, path, patch, added, removed):
            return SessionTranscriptLine(
                id: "d-\(id.uuidString)",
                kind: .diff,
                text: patch,
                path: path,
                added: added,
                removed: removed
            )
        case let .notice(id, text):
            return SessionTranscriptLine(id: "n-\(id.uuidString)", kind: .notice, text: text)
        }
    }

    private static func item(from line: SessionTranscriptLine) -> Item {
        switch line.kind {
        case .user:
            return .user(id: UUID(uuidString: line.id.replacingOccurrences(of: "u-", with: "")) ?? UUID(), text: line.text)
        case .assistant:
            return .assistant(id: UUID(uuidString: line.id.replacingOccurrences(of: "a-", with: "")) ?? UUID(), text: line.text)
        case .tool:
            let toolId = line.id.hasPrefix("t-") ? String(line.id.dropFirst(2)) : line.id
            return .tool(id: toolId, tool: line.tool ?? "tool", summary: line.text, ok: line.ok, output: nil)
        case .diff:
            return .diff(
                id: UUID(uuidString: line.id.replacingOccurrences(of: "d-", with: "")) ?? UUID(),
                path: line.path ?? "file",
                patch: line.text,
                added: line.added ?? 0,
                removed: line.removed ?? 0
            )
        case .notice:
            return .notice(id: UUID(uuidString: line.id.replacingOccurrences(of: "n-", with: "")) ?? UUID(), text: line.text)
        }
    }

    func start() {
        guard streamTask == nil else { return }
        isSessionReady = false
        isRunning = false
        connectionError = nil
        connectionStatusLine = "Connecting to desktop…"
        streamTask = Task { await run() }
        // Ports are optional UX — wait until the agent session exists so we
        // don't open extra tunnel sockets during a flaky first connect.
    }

    /// User-initiated reconnect after a failed or dropped session socket.
    func retryConnection() {
        streamTask?.cancel()
        streamTask = nil
        portsTask?.cancel()
        portsTask = nil
        Task { await client.disconnect() }
        start()
    }

    private func run() async {
        let token = state?.serverToken ?? config.token
        // Refresh API key / model from current settings when resuming so
        // expired keys or model switches still work against the same workdir.
        let model = state?.modelSelectionForSession() ?? config.model
        var repo = config.repo
        if let gh = state?.githubToken, !gh.isEmpty {
            repo.githubToken = gh
        }

        guard !token.isEmpty else {
            connectionError = "Not paired with a desktop server."
            connectionStatusLine = "Not paired"
            appendNotice("Pair a desktop server in Settings, then try again.")
            return
        }

        let candidates = connectionCandidates()
        guard !candidates.isEmpty else {
            connectionError = "No server address available."
            connectionStatusLine = "Failed"
            appendNotice("Re-pair the desktop server in Settings.")
            return
        }

        connectionError = nil
        if config.resuming {
            appendNotice("Reconnecting to session…")
        } else {
            appendNotice("Connecting… cloning repo on desktop if needed.")
        }

        var lastError: Error?
        for (index, endpoint) in candidates.enumerated() {
            let pathLabel = AppState.connectionPath(for: endpoint).label
            let host = endpoint.baseURL.host ?? endpoint.baseURL.absoluteString
            connectionStatusLine = "Connecting via \(pathLabel) (\(host))…"
            do {
                // `connect` waits until the WebSocket is open before returning —
                // sending create_session earlier races and yields "Socket is not connected".
                let stream = try await client.connect(endpoint: endpoint, token: token)
                // Remember which path worked so future sends / tools use it.
                state?.activateEndpointForSession(endpoint)
                connectionStatusLine = "Connected via \(pathLabel) — starting session…"
                try await client.send(.createSession(
                    sessionId: sessionID,
                    repo: repo,
                    environment: config.environment,
                    model: model,
                    permissionMode: config.permissionMode,
                    skills: config.skills,
                    mcpServers: config.mcpServers))
                connectionStatusLine = "Waiting for session…"
                for await message in stream {
                    handle(message)
                }
                // Stream ended (desktop closed socket or network drop).
                if isSessionReady {
                    connectionError = "Disconnected from desktop."
                    connectionStatusLine = "Disconnected"
                    appendNotice("Connection closed. Tap Retry or leave and reopen the session.")
                } else if connectionError == nil {
                    connectionError = "Could not start session (connection closed)."
                    connectionStatusLine = "Failed"
                    appendNotice("Desktop closed the connection before the session was ready. Check Local vs Tunnel, or re-pair if the desktop restarted.")
                }
                lastError = nil
                break
            } catch {
                lastError = error
                await client.disconnect()
                let detail = error.localizedDescription
                let unauthorized = detail.localizedCaseInsensitiveContains("unauthorized")
                    || detail.localizedCaseInsensitiveContains("re-pair")
                // Don't burn through fallbacks on a bad token — every path will fail the same way.
                if unauthorized {
                    connectionError = detail
                    connectionStatusLine = "Re-pair required"
                    appendNotice(detail)
                    appendNotice("Open Settings → Pair server (desktop tokens reset when the desktop restarts).")
                    break
                }
                let more = index + 1 < candidates.count
                appendNotice(
                    more
                        ? "\(pathLabel) failed (\(detail)). Trying next path…"
                        : "Could not connect via \(pathLabel): \(detail)"
                )
            }
        }

        if let lastError, !isSessionReady, connectionError == nil {
            connectionError = lastError.localizedDescription
            connectionStatusLine = "Failed"
        }
        isSessionReady = false
        isRunning = false
    }

    /// Ordered endpoints to try for this session: preference first, then fallbacks.
    private func connectionCandidates() -> [ServerClient.Endpoint] {
        var ordered: [ServerClient.Endpoint] = []
        var seen = Set<String>()

        func append(_ endpoint: ServerClient.Endpoint?) {
            guard let endpoint else { return }
            let key = endpoint.baseURL.absoluteString
            guard !seen.contains(key) else { return }
            seen.insert(key)
            ordered.append(endpoint)
        }

        let pref = state?.connectionPreference ?? .smart
        let active = state?.serverEndpoint ?? config.endpoint
        let local = state?.localEndpoint
        let tunnel = state?.tunnelEndpoint

        switch pref {
        case .alwaysLocal:
            append(local)
            append(active)
            append(tunnel)
        case .alwaysTunnel:
            append(tunnel)
            append(active)
            append(local)
        case .smart:
            // Prefer tunnel, fall back to local (and any active path).
            append(tunnel)
            append(local)
            append(active)
        }

        // Config snapshot as final fallback (frozen at session open).
        append(config.endpoint)
        return ordered
    }

    /// Finish the session: commit + push + open PR (never merge).
    func finishWithPR() {
        prepareCommitMessage(generateWithAI: true)
        // Give AI a moment; user can also edit via git sheet. For one-tap Done
        // use the current/fallback message.
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = message.isEmpty ? fallbackCommitMessage() : message
        gitPublish(message: title, commit: true, push: true, openPr: true)
        if let localId = config.localSessionId {
            state?.codeSessionStore.update(localId) { $0.status = .readyForReview }
        }
    }

    private func pollPortsLoop() async {
        while !Task.isCancelled {
            await refreshPorts()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    func refreshPorts() async {
        let endpoint = state?.serverEndpoint ?? config.endpoint
        let token = state?.serverToken ?? config.token
        guard !token.isEmpty else { return }
        do {
            let ports = try await WorkspaceRPC.withConnection(
                endpoint: endpoint,
                token: token,
                timeoutSeconds: 8,
                send: { try await $0.send(.portList(sessionId: sessionID)) },
                match: { msg -> [ServerMessage.PortEntryPayload]? in
                    if case let .portListResult(_, ports) = msg { return ports }
                    return nil
                }
            )
            openPorts = ports
            primaryWebPort = Self.pickWebPort(from: ports)
            if let port = primaryWebPort {
                // Prefer a public tunnel URL when the desktop already exposed it;
                // otherwise fall back to the LAN host from the paired endpoint.
                webPreviewURL = Self.previewURL(port: port, endpoint: config.endpoint)
            } else {
                webPreviewURL = nil
            }
        } catch {
            // Soft-fail — ports are optional UX.
        }
    }

    /// Start a public tunnel for a port so the phone can preview off-LAN.
    func exposePortForPreview(_ port: Int) async -> URL? {
        let endpoint = state?.serverEndpoint ?? config.endpoint
        let token = state?.serverToken ?? config.token
        guard !token.isEmpty else { return nil }
        do {
            let status = try await WorkspaceRPC.withConnection(
                endpoint: endpoint,
                token: token,
                timeoutSeconds: 25,
                send: {
                    try await $0.send(.tunnelStart(
                        sessionId: sessionID,
                        port: port,
                        provider: "auto"
                    ))
                },
                match: { msg -> [ServerMessage.TunnelPayload]? in
                    if case let .tunnelStatus(_, tunnels, _) = msg { return tunnels }
                    return nil
                }
            )
            if let urlStr = status.first(where: { $0.port == port && $0.url != nil })?.url,
               let url = URL(string: urlStr) {
                webPreviewURL = url
                return url
            }
        } catch {
            appendNotice("Could not expose port \(port): \(error.localizedDescription)")
        }
        return nil
    }

    private static func pickWebPort(from ports: [ServerMessage.PortEntryPayload]) -> Int? {
        let set = Set(ports.map(\.port))
        for preferred in preferredWebPorts where set.contains(preferred) {
            return preferred
        }
        // Heuristic: node / vite / next / python http.server style commands.
        let webby = ports.first { entry in
            let cmd = entry.command.lowercased()
            return cmd.contains("node") || cmd.contains("vite") || cmd.contains("next")
                || cmd.contains("webpack") || cmd.contains("python") || cmd.contains("uvicorn")
                || cmd.contains("ruby") || cmd.contains("php") || cmd.contains("deno")
                || cmd.contains("bun")
        }
        return webby?.port ?? ports.first?.port
    }

    private static func previewURL(port: Int, endpoint: ServerClient.Endpoint) -> URL? {
        // Use the paired server host (LAN IP or localhost) with the app port.
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        components?.port = port
        components?.path = "/"
        components?.query = nil
        return components?.url
    }

    func sendUserMessage(_ text: String) {
        transmitUserMessage(text, showBubble: true)
    }

    /// Send (and optionally render) a user message on the live agent socket.
    private func transmitUserMessage(_ text: String, showBubble: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if showBubble {
            items.append(.user(id: UUID(), text: trimmed))
            scheduleTranscriptSave()
        }

        guard isSessionReady else {
            // Not ready yet (still cloning / connecting) — queue until session_created.
            if !pendingOutgoing.contains(trimmed) {
                pendingOutgoing.append(trimmed)
            }
            appendNotice("Queued — waiting for desktop session…")
            return
        }

        isRunning = true
        connectionStatusLine = nil
        connectionError = nil
        // Always send the live model selection so mid-session picker changes apply.
        let model = state?.modelSelectionForSession()
        Task {
            do {
                try await client.send(.userMessage(sessionId: sessionID, text: trimmed, model: model))
            } catch {
                isRunning = false
                connectionError = error.localizedDescription
                connectionStatusLine = "Send failed"
                appendNotice("Could not send message: \(error.localizedDescription)")
                appendNotice("Tip: switch Local/Tunnel on the status pill, or tap Retry.")
            }
        }
    }

    /// Queue a follow-up that will fire after the current turn finishes.
    /// Still shows the user bubble immediately (previous behavior hid it).
    func queueMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(.user(id: UUID(), text: trimmed))
        scheduleTranscriptSave()
        pendingOutgoing.append(trimmed)
        queuedMessage = trimmed // keep published field for any UI that reads it
        appendNotice("Queued — will send after this turn.")
    }

    /// Send the next queued message (called when the agent goes idle).
    func sendQueuedMessageIfNeeded() {
        flushPendingOutgoing()
    }

    private func flushPendingOutgoing() {
        guard isSessionReady, !isRunning else { return }
        guard !pendingOutgoing.isEmpty else {
            queuedMessage = ""
            return
        }
        let next = pendingOutgoing.removeFirst()
        queuedMessage = pendingOutgoing.last ?? ""
        // Bubble already shown when queued — only transmit.
        isRunning = true
        connectionStatusLine = nil
        let model = state?.modelSelectionForSession()
        Task {
            do {
                try await client.send(.userMessage(sessionId: sessionID, text: next, model: model))
            } catch {
                isRunning = false
                connectionError = error.localizedDescription
                connectionStatusLine = "Send failed"
                appendNotice("Could not send message: \(error.localizedDescription)")
                // Put it back so the user can retry by waiting for reconnect/idle.
                pendingOutgoing.insert(next, at: 0)
            }
        }
    }

    func respond(to permission: PendingPermission, allow: Bool) {
        pendingPermission = nil
        Task {
            try? await client.send(.permissionResponse(
                sessionId: sessionID,
                requestId: permission.id,
                decision: allow ? .allow : .deny))
        }
    }

    func interrupt() {
        Task { try? await client.send(.interrupt(sessionId: sessionID)) }
    }

    func createPR(title: String) {
        gitPublish(message: title, commit: true, push: true, openPr: true)
    }

    /// Instant commit / push / open-PR (or any combination).
    func gitPublish(message: String, commit: Bool, push: Bool, openPr: Bool) {
        guard !isPublishing else { return }
        isPublishing = true
        let label = [
            commit ? "Commit" : nil,
            push ? "Push" : nil,
            openPr ? "PR" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        appendNotice("\(label)…")
        Task {
            do {
                try await client.send(.gitPublish(
                    sessionId: sessionID,
                    message: message,
                    commit: commit,
                    push: push,
                    openPr: openPr
                ))
            } catch {
                appendNotice("Error: \(error.localizedDescription)")
                isPublishing = false
            }
        }
    }

    /// Seed a commit message from the task + diffs, then optionally refine with AI.
    func prepareCommitMessage(generateWithAI: Bool = true) {
        if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitMessage = fallbackCommitMessage()
        }
        guard generateWithAI else { return }
        Task { await generateCommitMessageWithAI() }
    }

    /// Ask the session model for a concise conventional commit message.
    func generateCommitMessageWithAI() async {
        guard !isGeneratingCommitMessage else { return }
        isGeneratingCommitMessage = true
        defer { isGeneratingCommitMessage = false }

        let fallback = fallbackCommitMessage()
        let selection = state?.modelSelectionForSession() ?? config.model

        let diffSummary = diffSummaryForPrompt()
        let prompt = """
        Write a single-line git commit message for these changes.
        Prefer conventional commits style when it fits (e.g. "feat: …", "fix: …").
        Do not wrap in quotes. No body, only the subject line (max ~72 chars).

        Task: \(config.firstMessage)

        Diff summary:
        \(diffSummary)
        """

        do {
            let baseURL = state?.baseURL(for: selection.provider)
                ?? selection.baseURL.flatMap(URL.init(string:))
            let style = state?.apiStyle(for: selection.provider) ?? selection.apiStyle
            let reply = try await catalog.provider(
                selection.provider,
                customBaseURL: baseURL,
                style: style
            ).chat(
                model: selection.model,
                apiKey: selection.apiKey,
                messages: [
                    ProviderChatMessage(role: .system, content: "You write concise git commit messages."),
                    ProviderChatMessage(role: .user, content: prompt),
                ],
                effort: .low
            )
            let cleaned = reply
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                ?? ""
            commitMessage = cleaned.isEmpty ? fallback : cleaned
        } catch {
            if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commitMessage = fallback
            }
        }
    }

    private func fallbackCommitMessage() -> String {
        let task = config.firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty {
            // Keep a short subject-line style seed from the original task.
            let firstLine = task.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? task
            return String(firstLine.prefix(72))
        }
        let stats = totalDiffStats
        if stats.added + stats.removed > 0 {
            return "Update files (+\(stats.added)/-\(stats.removed))"
        }
        return "Update from AnyProv Code"
    }

    private func diffSummaryForPrompt() -> String {
        var lines: [String] = []
        for item in items {
            if case let .diff(_, path, patch, added, removed) = item {
                let snippet = patch
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(40)
                    .joined(separator: "\n")
                lines.append("### \(path) (+\(added)/-\(removed))\n\(snippet)")
            }
        }
        if lines.isEmpty {
            return "(no file diffs recorded yet — use the task description)"
        }
        // Cap prompt size for small models / free tiers.
        let joined = lines.joined(separator: "\n\n")
        return String(joined.prefix(6000))
    }

    // MARK: Event handling

    private func handle(_ message: ServerMessage) {
        switch message {
        case let .sessionCreated(_, _, _, workBranch):
            isSessionReady = true
            connectionError = nil
            connectionStatusLine = nil
            appendNotice("Session ready · branch \(workBranch)")
            // Start optional ports polling only after the session exists.
            if portsTask == nil {
                portsTask = Task { await pollPortsLoop() }
            }
            if config.resuming {
                isRunning = false
                flushPendingOutgoing()
            } else {
                // Kick off the first user turn once the repo is cloned.
                let first = config.firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                if !first.isEmpty {
                    // Drop any pre-ready queue of the same opener so we don't double-send.
                    pendingOutgoing.removeAll { $0 == first }
                    let alreadyShown = items.contains { item in
                        if case let .user(_, text) = item { return text == first }
                        return false
                    }
                    transmitUserMessage(first, showBubble: !alreadyShown)
                } else {
                    isRunning = false
                    flushPendingOutgoing()
                }
            }

        case let .assistantDelta(_, text):
            isRunning = true
            connectionStatusLine = nil
            appendAssistant(text)

        case let .toolCall(_, callId, tool, summary):
            isRunning = true
            items.append(.tool(id: callId, tool: tool, summary: summary, ok: nil, output: nil))
            scheduleTranscriptSave()

        case let .toolResult(_, callId, ok, output):
            if let idx = items.firstIndex(where: { if case let .tool(id, _, _, _, _) = $0 { return id == callId } else { return false } }),
               case let .tool(id, tool, summary, _, _) = items[idx] {
                items[idx] = .tool(id: id, tool: tool, summary: summary, ok: ok, output: output)
            }
            scheduleTranscriptSave()

        case let .diff(_, path, patch, added, removed):
            items.append(.diff(id: UUID(), path: path, patch: patch, added: added, removed: removed))
            scheduleTranscriptSave()

        case let .permissionRequest(_, requestId, tool, summary):
            pendingPermission = PendingPermission(id: requestId, tool: tool, summary: summary)

        case .sessionDone:
            isRunning = false
            flushPendingOutgoing()
            scheduleTranscriptSave()
            // Archived with "keep running": drop the phone socket once the turn ends.
            if let localId = config.localSessionId,
               let row = state?.codeSessionStore.session(id: localId),
               row.status == .archived || row.disconnectWhenDone {
                state?.codeSessionStore.update(localId) {
                    $0.disconnectWhenDone = false
                    if $0.status != .archived { $0.status = .completed }
                }
                persistTranscript()
                Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    await client.disconnect()
                    connectionStatusLine = "Archived — disconnected."
                    isSessionReady = false
                }
            }

        case let .prCreated(_, url):
            prURL = URL(string: url)
            appendNotice("Pull request ready (not merged).")
            if let localId = config.localSessionId {
                state?.codeSessionStore.update(localId) {
                    $0.prURL = url
                    $0.status = .readyForReview
                }
            }

        case let .gitResult(_, action, ok, detail, _):
            isPublishing = false
            // Browser open is driven by `pr_created` only (openPr flow).
            appendNotice(ok ? detail : "Git \(action) failed: \(detail)")

        case let .error(_, message):
            // Soft pre-session noise (skills sync, project env notes) must not
            // lock the composer or mark the socket as dead.
            let fatal = Self.isFatalSessionError(message)
            appendNotice("Error: \(message)")
            if fatal && !isSessionReady {
                connectionError = message
                connectionStatusLine = "Failed"
            }
            if isSessionReady {
                isRunning = false
                isPublishing = false
                flushPendingOutgoing()
            }

        case let .skillsSync(skills):
            state?.skillManager.apply(skills: skills)

        case let .mcpSync(servers):
            state?.mcpManager.apply(servers: servers)

        case let .remoteEndpoint(status, url, _, _):
            if status == "up", let url, !url.isEmpty {
                _ = state?.applyRemoteEndpoint(urlString: url)
            }

        case .terminalData, .terminalControl, .fileListResult, .fileReadResult, .fileWriteResult, .portListResult, .tunnelStatus:
            // Handled by the dedicated tools views via their own connection.
            break
        }
    }

    private static func isFatalSessionError(_ message: String) -> Bool {
        let m = message.lowercased()
        if m.contains("skills sync") || m.contains("mcp sync") { return false }
        if m.contains("env var") || m.contains("project config provided") { return false }
        return true
    }

    private func appendAssistant(_ text: String) {
        if case let .assistant(id, existing) = items.last {
            items[items.count - 1] = .assistant(id: id, text: existing + text)
        } else {
            items.append(.assistant(id: UUID(), text: text))
        }
        scheduleTranscriptSave()
    }

    private func appendNotice(_ text: String) {
        items.append(.notice(id: UUID(), text: text))
        scheduleTranscriptSave()
    }

    var totalDiffStats: (added: Int, removed: Int) {
        items.reduce(into: (0, 0)) { acc, item in
            if case let .diff(_, _, _, added, removed) = item {
                acc.0 += added
                acc.1 += removed
            }
        }
    }

    var hasDiffs: Bool {
        items.contains { if case .diff = $0 { return true } else { return false } }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        portsTask?.cancel()
        portsTask = nil
        Task { await client.disconnect() }
    }

    var workBranch: String { config.repo.workBranch }
    var hasWebPreview: Bool { primaryWebPort != nil }
}
