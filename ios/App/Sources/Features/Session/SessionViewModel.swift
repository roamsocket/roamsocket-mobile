import Foundation
import SwiftUI
import Combine
import MobileAICore

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
    @Published var sessionID: String = "s_\(UUID().uuidString.prefix(8))"
    @Published var connectionError: String?

    private let config: SessionConfig
    private let client: ServerClient
    private var streamTask: Task<Void, Never>?

    init(config: SessionConfig, client: ServerClient) {
        self.config = config
        self.client = client
    }

    func start() {
        guard streamTask == nil else { return }
        isRunning = true
        streamTask = Task { await run() }
    }

    private func run() async {
        do {
            let stream = try await client.connect(endpoint: config.endpoint, token: config.token)
            try await client.send(.createSession(
                sessionId: sessionID,
                repo: config.repo,
                environment: config.environment,
                model: config.model,
                permissionMode: config.permissionMode))
            for await message in stream {
                handle(message)
            }
        } catch {
            connectionError = error.localizedDescription
        }
        isRunning = false
    }

    func sendUserMessage(_ text: String) {
        appendNotice("You: \(text)")
        isRunning = true
        Task {
            try? await client.send(.userMessage(sessionId: sessionID, text: text))
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
        Task {
            try? await client.send(.createPR(sessionId: sessionID, title: title, body: "Created with code-mobile-ai."))
        }
    }

    // MARK: Event handling

    private func handle(_ message: ServerMessage) {
        switch message {
        case .sessionCreated:
            // Kick off the first user turn once the repo is cloned.
            sendUserMessage(config.firstMessage)

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
            appendNotice("Pull request ready.")

        case let .error(_, message):
            appendNotice("Error: \(message)")
            isRunning = false
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
        Task { await client.disconnect() }
    }
}
