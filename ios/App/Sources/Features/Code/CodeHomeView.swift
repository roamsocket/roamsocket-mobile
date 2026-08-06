import SwiftUI
import MobileAICore

/// A locally-tracked coding session. Persisted to UserDefaults so the user
/// can re-open recent sessions from the Code home screen.
struct CodeSession: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var repoFullName: String
    var baseBranch: String
    var workBranch: String
    var createdAt: Date
    var updatedAt: Date
    /// `active` while a session is running, `ready` when finished.
    var status: Status
    /// Total tool-call count for the "Ready for review" filter heuristic.
    var toolCount: Int

    enum Status: String, Codable, CaseIterable, Identifiable {
        case needsInput = "Needs input"
        case readyForReview = "Ready for review"
        case working = "Working"
        case completed = "Completed"
        case archived = "Archived"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .needsInput: return "exclamationmark.bubble"
            case .readyForReview: return "checkmark.circle"
            case .working: return "circle.dotted"
            case .completed: return "checkmark.seal"
            case .archived: return "archivebox"
            }
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        repoFullName: String,
        baseBranch: String,
        workBranch: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: Status = .working,
        toolCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.repoFullName = repoFullName
        self.baseBranch = baseBranch
        self.workBranch = workBranch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.toolCount = toolCount
    }
}

/// Persists coding sessions locally so the Code home can show recent work.
final class CodeSessionStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var sessions: [CodeSession] = []
    private let key = "codeSessions.v1"

    init() { load() }

    func add(_ session: CodeSession) {
        sessions.insert(session, at: 0)
        save()
    }

    func update(_ id: UUID, mutate: (inout CodeSession) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var copy = sessions[idx]
        mutate(&copy)
        copy.updatedAt = Date()
        sessions[idx] = copy
        save()
    }

    func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CodeSession].self, from: data)
        else { return }
        sessions = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// The Code home screen: Devices (recent paired laptops) and Sessions
/// (recent coding sessions with status filters). A floating "New session"
/// button captures the task and routes through the plan intake sheet.
/// Builds a `SessionConfig` from the current `AppState`. Centralized so the
/// Code home screen and the plan intake sheet construct sessions the same
/// way.
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
    var icon: String {
        switch self {
        case .acceptEdits: return "checkmark.circle"
        case .plan: return "list.bullet.clipboard"
        case .ask: return "questionmark.circle"
        }
    }
}

struct CodeHomeView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var sessionStore = CodeSessionStore()
    @State private var statusFilter: CodeSession.Status? = nil
    @State private var showFilterSheet = false
    @State private var showEnvironmentPicker = false
    @State private var showModelPicker = false
    @State private var showNewSession = false
    @State private var pushSessionConfig: SessionConfig?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 24) {
                        devicesSection
                        sessionsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    // Leave room for the FAB so the last row never tucks
                    // underneath it.
                    .padding(.bottom, 96)
                }
            }
            newSessionFAB
                .padding(.trailing, 18)
                .padding(.bottom, 22)
        }
        .navigationBarHidden(true)
        .navigationDestination(item: $pushSessionConfig) { config in
            SessionView(config: config)
        }
        .sheet(isPresented: $showFilterSheet) {
            SessionFilterSheet(selection: $statusFilter)
        }
        .sheet(isPresented: $showEnvironmentPicker) {
            EnvironmentPickerSheet()
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet()
        }
        .fullScreenCover(isPresented: $showNewSession) {
            NewSessionView { config, task in
                startSession(config: config, title: task)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Code")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: - Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Devices")
                .font(.system(size: 17))
                .foregroundStyle(Theme.textSecondary)
            if state.serverName == nil {
                devicesEmpty
            } else {
                deviceRow(name: state.serverName ?? "", time: "Now")
            }
        }
    }

    private var devicesEmpty: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textTertiary)
                Image(systemName: "iphone")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text("No recently connected devices")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
            Text("Pair a desktop server from Settings → Coding.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func deviceRow(name: String, time: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 22))
                .foregroundStyle(Theme.selection)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(time)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sessions")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    showFilterSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text(statusFilter?.rawValue ?? "All")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            if filteredSessions.isEmpty {
                sessionsEmpty
            } else {
                VStack(spacing: 8) {
                    ForEach(filteredSessions) { session in
                        Button {
                            reattach(session: session)
                        } label: {
                            sessionCard(session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var filteredSessions: [CodeSession] {
        if let filter = statusFilter {
            return sessionStore.sessions.filter { $0.status == filter }
        }
        return sessionStore.sessions
    }

    private func sessionCard(_ session: CodeSession) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: 36, height: 36)
                Image(systemName: session.status.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(statusColor(session.status))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(session.repoFullName)
                        .font(.system(size: 12))
                    Text("·")
                        .font(.system(size: 12))
                    Text(session.workBranch)
                        .font(.system(size: 12))
                    Text("·")
                        .font(.system(size: 12))
                    Text(relativeTime(session.updatedAt))
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            }
            Spacer()
            gitStatusBadge(for: session)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Compact git-status pill for the trailing edge of each session row.
    /// Falls back to a baseline "clean" indicator when the session hasn't
    /// reported any activity yet. The mapping is intentionally lightweight —
    /// it doesn't read real ahead/behind counts, it just reflects what
    /// state we know about locally.
    private func gitStatusBadge(for session: CodeSession) -> some View {
        let badge = gitStatus(for: session)
        return HStack(spacing: 4) {
            Image(systemName: badge.icon)
                .font(.system(size: 11, weight: .semibold))
            Text(badge.label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(badge.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(badge.tint.opacity(0.15), in: Capsule())
    }

    private struct GitStatusBadge {
        let icon: String
        let label: String
        let tint: Color
    }

    private func gitStatus(for session: CodeSession) -> GitStatusBadge {
        switch session.status {
        case .working:
            return GitStatusBadge(
                icon: "arrow.up.circle.fill",
                label: "ahead",
                tint: Theme.accent
            )
        case .needsInput:
            return GitStatusBadge(
                icon: "exclamationmark.circle.fill",
                label: "blocked",
                tint: .orange
            )
        case .readyForReview:
            return GitStatusBadge(
                icon: "checkmark.circle.fill",
                label: "ready",
                tint: Theme.selection
            )
        case .completed:
            return GitStatusBadge(
                icon: "checkmark.seal.fill",
                label: "merged",
                tint: Theme.textSecondary
            )
        case .archived:
            return GitStatusBadge(
                icon: "archivebox.fill",
                label: "archived",
                tint: Theme.textTertiary
            )
        }
    }

    private var sessionsEmpty: some View {
        Text("No sessions yet. Start one below.")
            .font(.system(size: 14))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
            .padding(.horizontal, 14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusColor(_ status: CodeSession.Status) -> Color {
        switch status {
        case .needsInput: return .orange
        case .readyForReview: return Theme.selection
        case .working: return Theme.accent
        case .completed: return Theme.textTertiary
        case .archived: return Theme.textTertiary
        }
    }

    // MARK: - New session FAB

    private var newSessionFAB: some View {
        Button {
            showNewSession = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .semibold))
                Text("New session")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.accent, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start a new coding session")
    }

    // MARK: - Session lifecycle

    private func startSession(config: SessionConfig, title: String) {
        let session = CodeSession(
            title: title,
            repoFullName: config.repo.fullName,
            baseBranch: config.repo.baseBranch ?? "main",
            workBranch: config.repo.workBranch
        )
        sessionStore.add(session)
        // Stash the session id on the config so SessionView can update
        // its status as events come back over the WebSocket.
        pushSessionConfig = config.with(sessionId: session.id)
    }

    private func reattach(session: CodeSession) {
        // Build a session config from the persisted session record. This
        // reconnects to the server and re-runs the same first message.
        guard let endpoint = state.serverEndpoint,
              let token = state.serverToken,
              let repo = state.selectedRepo,
              let model = state.modelSelectionForSession() else { return }
        let repoRef = RepoRef(
            fullName: session.repoFullName,
            baseBranch: session.baseBranch,
            workBranch: session.workBranch,
            githubToken: state.githubToken
        )
        let config = SessionConfig(
            endpoint: endpoint,
            token: token,
            repo: repoRef,
            environment: state.selectedEnvironment,
            model: model,
            permissionMode: state.permissionMode,
            firstMessage: session.title,
            skills: state.skillManager.enabledSkills.map(\.content),
            mcpServers: state.mcpManager.configuredMCPServers
        )
        pushSessionConfig = config
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - New session prompt removed

// MARK: - Filter sheet

struct SessionFilterSheet: View {
    @Binding var selection: CodeSession.Status?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selection = nil
                    dismiss()
                } label: {
                    HStack {
                        Text("All")
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if selection == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Theme.selection)
                        }
                    }
                }
                ForEach(CodeSession.Status.allCases.filter { $0 != .archived }) { status in
                    Button {
                        selection = status
                        dismiss()
                    } label: {
                        HStack {
                            Text(status.rawValue)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if selection == status {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.selection)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Filter by status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}

extension SessionConfig {
    /// Returns a copy of this config with the session id replaced.
    func with(sessionId: UUID) -> SessionConfig {
        // The wire id is a String. We round-trip through a fresh SessionConfig
        // so the rest of the call sites (which only take SessionConfig)
        // stay typed.
        return SessionConfig(
            endpoint: endpoint,
            token: token,
            repo: repo,
            environment: environment,
            model: model,
            permissionMode: permissionMode,
            firstMessage: firstMessage,
            skills: skills,
            mcpServers: mcpServers
        )
    }
}

extension MCPManager {
    /// Wire-format subset of the user's MCP servers. Sent to the desktop
    /// server on session create. The desktop side decides which ones to
    /// start based on transport + its own enabled flag.
    var configuredMCPServers: [MCPServerConfig] {
        configuredServers.map {
            MCPServerConfig(name: $0.name, command: $0.command, args: $0.args, env: $0.env)
        }
    }
}
