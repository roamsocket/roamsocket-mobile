import Foundation
import AnyProvCore

/// Builds a `SessionConfig` for the desktop-mediated Code flow that
/// `ChatView` opens via a fullScreenCover. Still wired up because
/// the chat → code session path (open a coding session from a
/// chat message) is the only entry point into the desktop agent
/// loop that doesn't require a desktop E2B sandbox.
///
/// The Code home screen does not use this — it runs phone-only
/// E2B sandboxes via `DirectE2BClient`. The two flows are
/// independent: a paired desktop is required for
/// `SessionLauncher.makeConfig` to return a non-nil config, and
/// it's the chat → session path that surfaces the desktop's
/// agent loop.
@MainActor
enum SessionLauncher {
    /// Build a session config for the given task description. Returns nil when
    /// the prerequisites (paired server, selected repo, model with API key)
    /// aren't met — callers should surface a friendly error in that case.
    static func makeConfig(
        in state: AppState,
        task: String,
        skills: [Skill]? = nil,
        mcpServers: [MCPServerConfig]? = nil
    ) -> SessionConfig? {
        guard let endpoint = state.serverEndpoint,
              let token = state.serverToken,
              let repo = state.selectedRepo,
              let model = state.modelSelectionForSession() else {
            return nil
        }
        let activeSkills = skills ?? state.skillManager.enabledSkills
        let activeMCP = mcpServers ?? state.mcpManager.configuredServers.map { MCPServerConfig($0) }
        let prefix = state.codeBranchPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchPrefix = prefix.isEmpty ? "roamsocket" : prefix
        let workBranch = "\(branchPrefix)/\(slug(from: task))-\(shortId())"
        let wireId = "s_\(shortId())"
        let repoRef = RepoRef(
            fullName: repo.fullName,
            baseBranch: repo.defaultBranch,
            workBranch: workBranch,
            githubToken: state.githubToken
        )
        return SessionConfig(
            wireSessionId: wireId,
            endpoint: endpoint,
            token: token,
            repo: repoRef,
            environment: state.selectedEnvironment,
            model: model,
            permissionMode: state.permissionMode,
            firstMessage: task,
            skills: activeSkills.map(\.content),
            mcpServers: activeMCP
        )
    }

    static func missingRequirements(in state: AppState) -> [String] {
        var missing: [String] = []
        if state.serverToken == nil || state.serverName == nil {
            missing.append("Pair a desktop server in Settings.")
        }
        if state.selectedRepo == nil {
            missing.append("Choose a repository on the home screen.")
        }
        if state.selectedModel == nil {
            missing.append("Pick a model.")
        } else if state.resolvedAPIKey(for: state.selectedModel!.provider).isEmpty {
            missing.append("Add an API key for \(state.selectedModel!.provider.displayName).")
        }
        return missing
    }

    private static func slug(from text: String) -> String {
        let lowered = text.lowercased()
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(40))
    }

    private static func shortId() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

extension PermissionMode {
    /// Icon for the permission-mode chip. Lives next to
    /// `SessionLauncher` because both are part of the chat →
    /// code-session flow.
    var icon: String {
        switch self {
        case .acceptEdits: return "checkmark.circle"
        case .plan: return "list.bullet.clipboard"
        case .ask: return "questionmark.circle"
        }
    }
}
