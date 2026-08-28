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
    @Published private(set) var isRunning = false
    /// True after `session_created` — safe to send user messages.
    @Published private(set) var isSessionReady = false
    @Published var pendingPermission: PendingPermission?
    @Published var prURL: URL?
    /// Wire protocol session id — used by SSH / Files / ports against the desktop.
    @Published private(set) var sessionID: String
    @Published var connectionError: String?
    /// Short status under the env pill (Connecting… / Disconnected / nil when healthy).
    @Published var connectionStatusLine: String? = "Connecting…"
    /// True when the desktop token is missing/invalid and the user must enter a new pairing code.
    @Published var needsRePair = false
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
    /// Agent working checklist from `task_list` / `update_tasks`.
    @Published private(set) var agentTasks: [ServerMessage.AgentTaskPayload] = []
    /// Active `/goal` condition for this coding session (banner + status).
    @Published private(set) var goalStatus: ServerMessage.GoalStatusPayload?
    /// Live local-model loading state for this coding session (banner + status).
    @Published private(set) var modelStatus: ServerMessage.ModelStatusPayload?

    /// Composer accepts text once the desktop session exists.
    /// Soft notices (skills sync, project env warnings) must not block input.
    var canAcceptInput: Bool { isSessionReady }

    private let config: SessionConfig
    private let client: ServerClient
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
        setAgentRunning(false)
        connectionError = nil
        needsRePair = false
        connectionStatusLine = "Connecting to desktop…"
        streamTask = Task { await run() }
        // Ports are optional UX — wait until the agent session exists so we
        // don't open extra tunnel sockets during a flaky first connect.
    }

    /// Updates local `isRunning` and the persisted session flag used by archive.
    private func setAgentRunning(_ active: Bool) {
        let wasRunning = isRunning
        isRunning = active
        if active, !wasRunning {
            AIThinkingActivityManager.shared.thinkingDidStart(
                kind: .code,
                prompt: lastUserPromptPreview()
            )
        } else if !active, wasRunning {
            AIThinkingActivityManager.shared.thinkingDidEnd()
        }
        guard let localId = config.localSessionId else { return }
        state?.codeSessionStore.setAgentActive(localId, active)
    }

    /// Best-effort prompt line for the Code Live Activity.
    private func lastUserPromptPreview() -> String {
        for item in items.reversed() {
            if case let .user(_, text) = item {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        let queued = queuedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !queued.isEmpty { return queued }
        return "Coding session"
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

    /// Foreground reconnect: reconnect only when the WebSocket is unhealthy.
    /// Called from `SessionView` when `scenePhase` flips to `.active` so the
    /// phone picks up the desktop's live progress (transcript replay) after
    /// being backgrounded. Idempotent — safe to call on every activation.
    func reconnectIfStale() {
        // streamTask stays non-nil while the loop is running; only reconnect
        // when it's missing or the run() loop already exited (cancelled
        // socket / failed handshake).
        let needsReconnect = !isSessionReady && connectionError != nil
        if needsReconnect || streamTask == nil {
            retryConnection()
        }
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
            failNeedsRePair(
                error: "Not paired with a desktop server.",
                status: "Not paired",
                notice: "Enter the pairing code shown on the desktop, then try again."
            )
            return
        }

        let candidates = connectionCandidates()
        guard !candidates.isEmpty else {
            failNeedsRePair(
                error: "No server address available.",
                status: "Failed",
                notice: "Enter a new pairing code from the desktop."
            )
            state?.markDesktopUnreachable("No server address available.")
            return
        }

        connectionError = nil
        needsRePair = false
        state?.markDesktopConnecting()
        if config.resuming {
            appendNotice("Reconnecting to session…")
        } else {
            appendNotice("Connecting… cloning repo on desktop if needed.")
        }

        var lastError: Error?
        for (index, endpoint) in candidates.enumerated() {
            let path = AppState.connectionPath(for: endpoint)
            let pathLabel = path.label
            let host = endpoint.baseURL.host ?? endpoint.baseURL.absoluteString
            connectionStatusLine = "Connecting via \(pathLabel) (\(host))…"
            do {
                // `connect` waits until the WebSocket is open before returning —
                // sending create_session earlier races and yields "Socket is not connected".
                let stream = try await client.connect(endpoint: endpoint, token: token)
                // Remember which path worked so future sends / tools use it.
                // activateEndpointForSession also kicks tunnel regen when we fell back to LAN.
                state?.activateEndpointForSession(endpoint)
                needsRePair = false
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
                    state?.markDesktopUnreachable("Disconnected from desktop.")
                } else if connectionError == nil {
                    connectionError = "Could not start session (connection closed)."
                    connectionStatusLine = "Failed"
                    appendNotice("Desktop closed the connection before the session was ready. Check Local vs Tunnel, or enter a new pairing code if the desktop restarted.")
                    state?.markDesktopUnreachable(connectionError)
                }
                lastError = nil
                break
            } catch {
                lastError = error
                await client.disconnect()
                let detail = error.localizedDescription
                // Don't burn through fallbacks on a bad token — every path will fail the same way.
                if Self.isUnauthorizedError(detail) {
                    failNeedsRePair(
                        error: detail,
                        status: "Re-pair required",
                        notice: "Desktop tokens reset when the desktop restarts. Enter the new pairing code to continue."
                    )
                    state?.markDesktopUnreachable(detail)
                    break
                }
                // Dead public tunnel: drop it so candidates/reconnect stop preferring it,
                // and request a fresh tunnel once LAN connects.
                if path == .tunnel {
                    state?.clearTunnelEndpoint(requestRegen: true)
                    appendNotice("Tunnel failed — falling back to local and refreshing the tunnel.")
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
            let detail = lastError.localizedDescription
            if Self.isUnauthorizedError(detail) {
                failNeedsRePair(
                    error: detail,
                    status: "Re-pair required",
                    notice: "Enter the new pairing code shown on the desktop."
                )
            } else {
                connectionError = detail
                connectionStatusLine = "Failed"
            }
            state?.markDesktopUnreachable(connectionError)
        }
        isSessionReady = false
        setAgentRunning(false)
    }

    /// Mark that the session cannot proceed until the user pairs again.
    private func failNeedsRePair(error: String, status: String, notice: String) {
        connectionError = error
        connectionStatusLine = status
        needsRePair = true
        appendNotice(notice)
    }

    static func isUnauthorizedError(_ detail: String) -> Bool {
        detail.localizedCaseInsensitiveContains("unauthorized")
            || detail.localizedCaseInsensitiveContains("re-pair")
            || detail.localizedCaseInsensitiveContains("token expired")
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

        setAgentRunning(true)
        connectionStatusLine = nil
        connectionError = nil
        // Always send the live model selection so mid-session picker changes apply.
        let model = state?.modelSelectionForSession()
        Task {
            do {
                try await client.send(.userMessage(sessionId: sessionID, text: trimmed, model: model))
            } catch {
                setAgentRunning(false)
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
        setAgentRunning(true)
        connectionStatusLine = nil
        let model = state?.modelSelectionForSession()
        Task {
            do {
                try await client.send(.userMessage(sessionId: sessionID, text: next, model: model))
            } catch {
                setAgentRunning(false)
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

    /// Seed a commit message from the task + diffs, then optionally refine with
    /// Apple's on-device Foundation Model (same path as chat title generation).
    func prepareCommitMessage(generateWithAI: Bool = true) {
        if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitMessage = fallbackCommitMessage()
        }
        guard generateWithAI else { return }
        Task { await generateCommitMessageWithAI() }
    }

    /// Prefer Apple Intelligence for a concise conventional commit subject;
    /// keeps the heuristic fallback when the on-device model is unavailable.
    func generateCommitMessageWithAI() async {
        guard !isGeneratingCommitMessage else { return }
        isGeneratingCommitMessage = true
        defer { isGeneratingCommitMessage = false }

        let fallback = fallbackCommitMessage()
        let suggested = await CommitMessageGenerator.suggest(
            task: config.firstMessage,
            diffSummary: diffSummaryForPrompt(),
            fallback: fallback
        )
        let trimmed = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
        commitMessage = trimmed.isEmpty ? fallback : trimmed
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
        return "Update from RoamSocket"
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
                setAgentRunning(false)
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
                    setAgentRunning(false)
                    flushPendingOutgoing()
                }
            }

        case let .assistantDelta(_, text):
            setAgentRunning(true)
            connectionStatusLine = nil
            modelStatus = nil
            appendAssistant(text)

        case let .toolCall(_, callId, tool, summary):
            setAgentRunning(true)
            items.append(.tool(id: callId, tool: tool, summary: summary, ok: nil, output: nil))
            let toolStatus = summary.isEmpty ? "Running \(tool)…" : summary
            AIThinkingActivityManager.shared.thinkingDidUpdate(status: toolStatus)
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
            setAgentRunning(false)
            modelStatus = nil
            flushPendingOutgoing()
            scheduleTranscriptSave()
            // Archived with "keep running": drop the phone socket once the turn ends.
            if let localId = config.localSessionId,
               let row = state?.codeSessionStore.session(id: localId),
               row.status == .archived || row.disconnectWhenDone {
                state?.codeSessionStore.update(localId) {
                    $0.disconnectWhenDone = false
                    $0.agentActive = false
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
                setAgentRunning(false)
                isPublishing = false
                flushPendingOutgoing()
            }

        case let .skillsSync(skills):
            state?.skillManager.apply(skills: skills)

        case let .mcpSync(servers):
            state?.mcpManager.apply(servers: servers)

        case let .memorySync(entries):
            let mapped = entries.map { p in
                UserMemoryStore.Entry(
                    id: p.id,
                    category: UserMemoryStore.Category(rawValue: p.category) ?? .you,
                    title: p.title,
                    summary: p.summary,
                    details: p.details,
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(p.updatedAt) / 1000.0)
                )
            }
            UserMemoryStore.shared.applySync(remoteEntries: mapped)

        case let .remoteEndpoint(status, url, _, _):
            if status == "up", let url, !url.isEmpty {
                // Health-check before switching so a stale auto-push can't yank us
                // off a working LAN path onto a dead tunnel.
                Task { @MainActor in
                    _ = await state?.applyRemoteEndpoint(urlString: url, requireReachable: true)
                }
            }

        case let .taskList(_, tasks):
            agentTasks = tasks

        case let .goalStatus(_, status, condition, reason, turnsEvaluated, startedAt, elapsedMs, message):
            let payload = ServerMessage.GoalStatusPayload(
                status: status,
                condition: condition,
                reason: reason,
                turnsEvaluated: turnsEvaluated,
                startedAt: startedAt,
                elapsedMs: elapsedMs,
                message: message
            )
            if status == "active" {
                goalStatus = payload
            } else if status == "achieved" {
                goalStatus = payload
            } else {
                // cleared / none — drop the live banner after showing notice
                goalStatus = nil
            }
            if !message.isEmpty {
                appendNotice(message)
            }

        case let .modelStatus(_, status, hubID, message):
            if status == "done" {
                modelStatus = nil
            } else {
                modelStatus = ServerMessage.ModelStatusPayload(
                    status: status,
                    hubID: hubID,
                    message: message
                )
            }

        case let .transcriptReplay(_, events, truncated, isLive):
            // Server replayed the rolling transcript because the phone's
            // socket dropped while the agent kept running on the desktop.
            // Replace the locally-cached items with the authoritative
            // server view, then resume streaming live events on the same
            // connection.
            items = rebuildItems(fromReplay: events)
            if isLive {
                setAgentRunning(true)
            } else {
                setAgentRunning(false)
            }
            let suffix = truncated ? " (earlier events trimmed)" : ""
            appendNotice("Synced \(events.count) events from desktop\(suffix).")
            scheduleTranscriptSave()

        case .terminalData, .terminalControl, .fileListResult, .fileReadResult, .fileWriteResult, .portListResult, .tunnelStatus, .remoteEndpoint, .connectorStatusMsg, .skillsSync, .mcpSync, .memorySync, .e2bStarted, .e2bLog, .e2bStatus, .e2bList, .e2bKeyAck:
            // Terminal / files / ports / tunnels are handled by the
            // dedicated tools views over their own connection. Remote
            // endpoint + connector / skills / MCP sync are surfaced in
            // the global AppState. E2B runs have their own Sandboxes
            // settings sheet; nothing to do here.
            break
        }
    }

    /// Rebuild the items array from a server-issued transcript replay. Mirrors
    /// the live `handle()` logic: assistant deltas coalesce, tool results
    /// update the matching call, diffs append. SessionDone is intentionally
    /// ignored here — `isLive` from the replay drives the running state.
    private func rebuildItems(fromReplay events: [ServerMessage.TranscriptEvent]) -> [Item] {
        var out: [Item] = []
        for event in events {
            switch event {
            case let .user(_, text):
                out.append(.user(id: UUID(), text: text))
            case let .assistantDelta(_, text):
                if case let .assistant(id, existing) = out.last {
                    out[out.count - 1] = .assistant(id: id, text: existing + text)
                } else {
                    out.append(.assistant(id: UUID(), text: text))
                }
            case let .toolCall(_, callId, tool, summary):
                out.append(.tool(id: callId, tool: tool, summary: summary, ok: nil, output: nil))
            case let .toolResult(_, callId, ok, output):
                if let idx = out.firstIndex(where: {
                    if case let .tool(id, _, _, _, _) = $0 { return id == callId }
                    return false
                }), case let .tool(id, tool, summary, _, _) = out[idx] {
                    out[idx] = .tool(id: id, tool: tool, summary: summary, ok: ok, output: output)
                }
            case let .diff(_, path, patch, added, removed):
                out.append(.diff(id: UUID(), path: path, patch: patch, added: added, removed: removed))
            }
        }
        return out
    }

    var taskProgress: (done: Int, total: Int) {
        let total = agentTasks.count
        let done = agentTasks.filter {
            $0.status == "completed" || $0.status == "cancelled"
        }.count
        return (done, total)
    }

    var hasAgentTasks: Bool { !agentTasks.isEmpty }

    var hasActiveGoal: Bool { goalStatus?.isActive == true }

    /// Show the goal strip for an in-flight or just-achieved condition.
    var showsGoalBanner: Bool {
        guard let status = goalStatus?.status else { return false }
        return status == "active" || status == "achieved"
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
        setAgentRunning(false)
        Task { await client.disconnect() }
    }

    var workBranch: String { config.repo.workBranch }
    var hasWebPreview: Bool { primaryWebPort != nil }
}
