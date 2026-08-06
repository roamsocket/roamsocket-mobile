import Foundation
import SwiftUI
import Combine
import AnyProvCore

/// Drives one coding session: connects to the server, streams protocol events
/// into a transcript, handles permission prompts, and creates the PR.
@MainActor
final class SessionViewModel: ObservableObject {
    enum Item: Identifiable {
        case assistant(id: UUID, text: String)
        case tool(id: String, tool: String, summary: String, ok: Bool?, output: String?)
        case diff(id: UUID, path: String, patch: String, added: Int, removed: Int)
        case notice(id: UUID, text: String)

        var id: String {
            switch self {
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
    @Published var isRunning = false
    @Published var pendingPermission: PendingPermission?
    @Published var prURL: URL?
    /// Wire protocol session id — used by SSH / Files / ports against the desktop.
    @Published private(set) var sessionID: String
    @Published var connectionError: String?
    /// Text the user typed while the agent is running. Sent when the
    /// current turn finishes. Queue for after
    /// this turn…" placeholder.
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

    private let config: SessionConfig
    private let client: ServerClient
    private let catalog = ModelCatalog()
    private var streamTask: Task<Void, Never>?
    private var portsTask: Task<Void, Never>?
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

    func start() {
        guard streamTask == nil else { return }
        isRunning = true
        streamTask = Task { await run() }
        portsTask = Task { await pollPortsLoop() }
    }

    private func run() async {
        // Prefer live pairing credentials so a reattached session works after
        // the app re-paired or auto-reconnected to the desktop.
        let endpoint = state?.serverEndpoint ?? config.endpoint
        let token = state?.serverToken ?? config.token
        // Refresh API key / model from current settings when resuming so
        // expired keys or model switches still work against the same workdir.
        let model = state?.modelSelectionForSession() ?? config.model
        var repo = config.repo
        if let gh = state?.githubToken, !gh.isEmpty {
            repo.githubToken = gh
        }
        do {
            connectionError = nil
            if config.resuming {
                appendNotice("Reconnecting to session…")
            }
            let stream = try await client.connect(endpoint: endpoint, token: token)
            try await client.send(.createSession(
                sessionId: sessionID,
                repo: repo,
                environment: config.environment,
                model: model,
                permissionMode: config.permissionMode,
                skills: config.skills,
                mcpServers: config.mcpServers))
            for await message in stream {
                handle(message)
            }
        } catch {
            connectionError = error.localizedDescription
            if config.resuming {
                appendNotice("Could not reconnect: \(error.localizedDescription)")
            }
        }
        isRunning = false
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
        appendNotice("You: \(text)")
        isRunning = true
        Task {
            try? await client.send(.userMessage(sessionId: sessionID, text: text))
        }
    }

    /// Queue a follow-up that will fire after the current turn finishes.
    func queueMessage(_ text: String) {
        queuedMessage = text
    }

    /// Send the queued message (called from `.onChange(of: isRunning)` when
    /// the agent transitions from running to idle).
    func sendQueuedMessageIfNeeded() {
        let text = queuedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queuedMessage = ""
        sendUserMessage(text)
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
            if config.resuming {
                appendNotice("Reconnected · branch \(workBranch)")
                isRunning = false
            } else {
                // Kick off the first user turn once the repo is cloned.
                sendUserMessage(config.firstMessage)
            }

        case let .assistantDelta(_, text):
            appendAssistant(text)

        case let .toolCall(_, callId, tool, summary):
            items.append(.tool(id: callId, tool: tool, summary: summary, ok: nil, output: nil))

        case let .toolResult(_, callId, ok, output):
            if let idx = items.firstIndex(where: { if case let .tool(id, _, _, _, _) = $0 { return id == callId } else { return false } }),
               case let .tool(id, tool, summary, _, _) = items[idx] {
                items[idx] = .tool(id: id, tool: tool, summary: summary, ok: ok, output: output)
            }

        case let .diff(_, path, patch, added, removed):
            items.append(.diff(id: UUID(), path: path, patch: patch, added: added, removed: removed))

        case let .permissionRequest(_, requestId, tool, summary):
            pendingPermission = PendingPermission(id: requestId, tool: tool, summary: summary)

        case .sessionDone:
            isRunning = false

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
            appendNotice("Error: \(message)")
            isRunning = false
            isPublishing = false

        case let .skillsSync(skills):
            state?.skillManager.apply(skills: skills)

        case let .mcpSync(servers):
            state?.mcpManager.apply(servers: servers)

        case .terminalData, .terminalControl, .fileListResult, .fileReadResult, .portListResult, .tunnelStatus:
            // Handled by the dedicated tools views via their own connection.
            break
        }
    }

    private func appendAssistant(_ text: String) {
        if case let .assistant(id, existing) = items.last {
            items[items.count - 1] = .assistant(id: id, text: existing + text)
        } else {
            items.append(.assistant(id: UUID(), text: text))
        }
    }

    private func appendNotice(_ text: String) {
        items.append(.notice(id: UUID(), text: text))
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
