import SwiftUI
import MobileAICore

/// Builds a `SessionConfig` from the current `AppState`. Centralized so the
/// composer, the Code home screen, and the "+" sheet all construct sessions
/// the same way.
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
        let activeMCP = mcpServers ?? state.mcpManager.configuredMCPServers
        let workBranch = "claude/\(slug(from: task))-\(shortId())"
        let repoRef = RepoRef(
            fullName: repo.fullName,
            baseBranch: repo.defaultBranch,
            workBranch: workBranch,
            githubToken: state.githubToken
        )
        return SessionConfig(
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

    /// Human-readable reasons the user can't start a session yet.
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
        } else if state.apiKey(for: state.selectedModel!.provider).isEmpty {
            missing.append("Add an API key for \(state.selectedModel!.provider.displayName).")
        }
        return missing
    }

    private static func slug(from text: String) -> String {
        let lowered = text.lowercased()
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
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
    var icon: String {
        switch self {
        case .acceptEdits: return "checkmark.circle"
        case .plan: return "list.bullet.clipboard"
        case .ask: return "questionmark.circle"
        }
    }
}

extension MCPManager {
    /// Wire-format subset of the user's enabled MCP servers. Sent to the
    /// desktop server on session create.
    var configuredMCPServers: [MCPServerConfig] {
        enabledServers.map {
            MCPServerConfig(name: $0.name, command: $0.command, args: $0.args, env: $0.env)
        }
    }
}

/// The Code section's home screen — shows the current pairing + repo + model
/// + environment status, lists any active skills, and exposes "New coding
/// session" to drop straight into a `SessionView` for the given task.
struct CodeHomeView: View {
    @EnvironmentObject var state: AppState
    @State private var task: String = ""
    @State private var pushSessionConfig: SessionConfig?
    @State private var showSkills = false
    @State private var showMCP = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        summaryCard
                        prerequisitesCard
                        skillsCard
                        mcpCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                composer
            }
        }
        .navigationTitle("Code")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pushSessionConfig) { config in
            SessionView(config: config)
        }
        .navigationDestination(isPresented: $showSkills) {
            InstalledSkillsView()
        }
        .navigationDestination(isPresented: $showMCP) {
            ConnectorManagerView()
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coding session")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 10) {
                row(systemImage: "desktopcomputer", title: "Server",
                    value: state.serverName ?? "Not paired",
                    ok: state.serverName != nil)
                row(systemImage: "folder", title: "Repository",
                    value: state.selectedRepo?.fullName ?? "None",
                    ok: state.selectedRepo != nil)
                row(systemImage: "cloud", title: "Environment",
                    value: state.selectedEnvironment?.name ?? "Default",
                    ok: state.selectedEnvironment != nil)
                row(systemImage: "cpu", title: "Model",
                    value: state.selectedModel.map { "\($0.displayName) · \(state.effort.displayName)" } ?? "None",
                    ok: state.selectedModel != nil)
                row(systemImage: state.permissionMode.icon, title: "Permissions",
                    value: state.permissionMode.displayName,
                    ok: true)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var prerequisitesCard: some View {
        let missing = SessionLauncher.missingRequirements(in: state)
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Before you can start")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(missing, id: \.self) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            Text(item)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var skillsCard: some View {
        let enabled = state.skillManager.enabledSkills
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Active skills")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Manage") { showSkills = true }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.selection)
            }
            VStack(alignment: .leading, spacing: 6) {
                if enabled.isEmpty {
                    Text("No skills active. The agent uses a default coding prompt.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(enabled) { skill in
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(Theme.selection)
                            Text(skill.name)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var mcpCard: some View {
        let configured = state.mcpManager.configuredMCPServers
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connectors")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Manage") { showMCP = true }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.selection)
            }
            VStack(alignment: .leading, spacing: 6) {
                if configured.isEmpty {
                    Text("No connectors configured.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(configured, id: \.name) { server in
                        HStack(spacing: 8) {
                            Image(systemName: "puzzlepiece")
                                .foregroundStyle(Theme.selection)
                            Text(server.name)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            TextField("Describe a coding task…", text: $task, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))

            HStack(spacing: 10) {
                Text(state.canStartSession ? "Ready" : "Not ready")
                    .font(.system(size: 13))
                    .foregroundStyle(state.canStartSession ? Theme.selection : Theme.textTertiary)
                Spacer()
                Button(action: startSession) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Start session")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(canStart ? Color.white : Theme.surfaceElevated, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.background)
    }

    private var canStart: Bool {
        state.canStartSession && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startSession() {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let config = SessionLauncher.makeConfig(in: state, task: text) else { return }
        pushSessionConfig = config
    }

    private func row(systemImage: String, title: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(ok ? Theme.selection : Theme.textTertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
        }
    }
}
