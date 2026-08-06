import SwiftUI
import AnyProvCore

/// A locally-tracked coding session. Persisted to UserDefaults so the user
/// can re-open recent sessions from the Code home screen.
/// One line of a coding-session transcript, persisted with the session for archives.
struct SessionTranscriptLine: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case user, assistant, tool, diff, notice }

    var id: String
    var kind: Kind
    var text: String
    var tool: String?
    var ok: Bool?
    var path: String?
    var added: Int?
    var removed: Int?

    init(
        id: String,
        kind: Kind,
        text: String,
        tool: String? = nil,
        ok: Bool? = nil,
        path: String? = nil,
        added: Int? = nil,
        removed: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.tool = tool
        self.ok = ok
        self.path = path
        self.added = added
        self.removed = removed
    }
}

struct CodeSession: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var repoFullName: String
    var baseBranch: String
    var workBranch: String
    /// Wire protocol session id used by the desktop SessionManager + tools.
    var wireSessionId: String
    /// Environment locked in when the session was created (not changeable later).
    var environment: EnvironmentConfig?
    /// Compare / pull-request URL after publish, if any.
    var prURL: String?
    var createdAt: Date
    var updatedAt: Date
    /// `active` while a session is running, `ready` when finished.
    var status: Status
    /// Total tool-call count for the "Ready for review" filter heuristic.
    var toolCount: Int
    /// Conversation snapshot (kept when archived so chats survive disconnect).
    var transcript: [SessionTranscriptLine]
    /// If true, leave the desktop agent running after archive; phone disconnects on next idle.
    var disconnectWhenDone: Bool

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

        /// Desktop agent may still be mid-turn.
        var mayBeRunning: Bool {
            switch self {
            case .working, .needsInput: return true
            default: return false
            }
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        repoFullName: String,
        baseBranch: String,
        workBranch: String,
        wireSessionId: String = "s_\(UUID().uuidString.prefix(8).lowercased())",
        environment: EnvironmentConfig? = nil,
        prURL: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: Status = .working,
        toolCount: Int = 0,
        transcript: [SessionTranscriptLine] = [],
        disconnectWhenDone: Bool = false
    ) {
        self.id = id
        self.title = title
        self.repoFullName = repoFullName
        self.baseBranch = baseBranch
        self.workBranch = workBranch
        self.wireSessionId = wireSessionId
        self.environment = environment
        self.prURL = prURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.toolCount = toolCount
        self.transcript = transcript
        self.disconnectWhenDone = disconnectWhenDone
    }

    enum CodingKeys: String, CodingKey {
        case id, title, repoFullName, baseBranch, workBranch
        case wireSessionId, environment, prURL, createdAt, updatedAt, status, toolCount
        case transcript, disconnectWhenDone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        repoFullName = try c.decode(String.self, forKey: .repoFullName)
        baseBranch = try c.decode(String.self, forKey: .baseBranch)
        workBranch = try c.decode(String.self, forKey: .workBranch)
        wireSessionId = try c.decodeIfPresent(String.self, forKey: .wireSessionId)
            ?? "s_\(id.uuidString.prefix(8).lowercased())"
        environment = try c.decodeIfPresent(EnvironmentConfig.self, forKey: .environment)
        prURL = try c.decodeIfPresent(String.self, forKey: .prURL)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        status = try c.decode(Status.self, forKey: .status)
        toolCount = try c.decodeIfPresent(Int.self, forKey: .toolCount) ?? 0
        transcript = try c.decodeIfPresent([SessionTranscriptLine].self, forKey: .transcript) ?? []
        disconnectWhenDone = try c.decodeIfPresent(Bool.self, forKey: .disconnectWhenDone) ?? false
    }
}

/// Persists coding sessions locally so the Code home can show recent work.
final class CodeSessionStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var sessions: [CodeSession] = []
    private let key = "codeSessions.v1"

    init() { load() }

    var activeSessions: [CodeSession] {
        sessions.filter { $0.status != .archived }
    }

    var archivedSessions: [CodeSession] {
        sessions.filter { $0.status == .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

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

    func session(id: UUID) -> CodeSession? {
        sessions.first { $0.id == id }
    }

    func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    /// Mark archived and optionally keep the desktop agent alive until idle.
    func archive(_ id: UUID, disconnectWhenDone: Bool) {
        update(id) {
            $0.status = .archived
            $0.disconnectWhenDone = disconnectWhenDone
        }
    }

    func unarchive(_ id: UUID) {
        update(id) {
            $0.status = .completed
            $0.disconnectWhenDone = false
        }
    }

    func saveTranscript(_ id: UUID, lines: [SessionTranscriptLine]) {
        update(id) { $0.transcript = lines }
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
        let prefix = state.codeBranchPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchPrefix = prefix.isEmpty ? "apc" : prefix
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
    @State private var statusFilter: CodeSession.Status? = nil
    @State private var showFilterSheet = false
    @State private var showEnvironmentPicker = false
    @State private var showModelPicker = false
    @State private var showNewSession = false
    @State private var showArchived = false
    @State private var pushSessionConfig: SessionConfig?
    @State private var archiveCandidate: CodeSession?
    @State private var showArchiveKillConfirm = false

    /// Opens the root sidebar drawer. Wired from `RootView` so Code can open
    /// the same destinations as Chat even though this screen hides the
    /// system navigation bar.
    var onOpenSidebar: () -> Void = {}

    private var sessionStore: CodeSessionStore { state.codeSessionStore }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                // Single List so swipe-to-archive works (swipeActions need List rows).
                List {
                    Section {
                        if state.serverName == nil {
                            devicesEmpty
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else {
                            deviceRow(name: state.serverName ?? "", time: "Now")
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("Devices")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.textSecondary)
                            .textCase(nil)
                    }

                    Section {
                        if filteredSessions.isEmpty {
                            sessionsEmpty
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(filteredSessions) { session in
                                Button {
                                    reattach(session: session)
                                } label: {
                                    sessionCard(session)
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        requestArchive(session)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(Theme.accent)
                                }
                            }
                        }
                    } header: {
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
                        .textCase(nil)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(.bottom, 80)
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
        .sheet(isPresented: $showArchived) {
            ArchivedSessionsView { session in
                showArchived = false
                reattach(session: session)
            }
            .environmentObject(state)
        }
        .fullScreenCover(isPresented: $showNewSession) {
            NewSessionView { config, task in
                startSession(config: config, title: task)
            }
        }
        .confirmationDialog(
            "Stop work on the desktop?",
            isPresented: $showArchiveKillConfirm,
            titleVisibility: .visible,
            presenting: archiveCandidate
        ) { session in
            Button("Stop agent and archive", role: .destructive) {
                performArchive(session, killAgent: true)
            }
            Button("Keep running, archive chat") {
                performArchive(session, killAgent: false)
            }
            Button("Cancel", role: .cancel) {
                archiveCandidate = nil
            }
        } message: { session in
            Text("“\(session.title)” may still be running on the desktop. Stop it, or leave it running and just archive this chat?")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onOpenSidebar) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open sidebar")

            Text("Code")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                showArchived = true
            } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
                    .overlay(alignment: .topTrailing) {
                        let n = sessionStore.archivedSessions.count
                        if n > 0 {
                            Text(n > 9 ? "9+" : "\(n)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.background)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.accent, in: Capsule())
                                .offset(x: 4, y: -2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived sessions")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: - Devices

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

    private var filteredSessions: [CodeSession] {
        let active = sessionStore.activeSessions
        if let filter = statusFilter, filter != .archived {
            return active.filter { $0.status == filter }
        }
        // Main list never shows archived rows (use header archive button).
        return active
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

    // MARK: - Archive

    private func requestArchive(_ session: CodeSession) {
        if session.status.mayBeRunning {
            archiveCandidate = session
            showArchiveKillConfirm = true
        } else {
            performArchive(session, killAgent: false)
        }
    }

    private func performArchive(_ session: CodeSession, killAgent: Bool) {
        archiveCandidate = nil
        if killAgent {
            Task { await interruptRemoteAgent(wireSessionId: session.wireSessionId) }
            sessionStore.archive(session.id, disconnectWhenDone: false)
        } else {
            // Leave desktop work running; phone should drop the WS when the turn ends.
            sessionStore.archive(session.id, disconnectWhenDone: session.status.mayBeRunning)
        }
        // If this session is open full-screen, close it so the connection policy applies.
        if pushSessionConfig?.localSessionId == session.id {
            if killAgent {
                pushSessionConfig = nil
            }
            // When keeping agent running, SessionViewModel observes disconnectWhenDone
            // and tears down the phone socket on session_done.
        }
    }

    private func interruptRemoteAgent(wireSessionId: String) async {
        guard let endpoint = state.serverEndpoint, let token = state.serverToken else { return }
        let client = ServerClient()
        do {
            _ = try await client.connect(endpoint: endpoint, token: token)
            try await client.send(.interrupt(sessionId: wireSessionId))
            try? await Task.sleep(nanoseconds: 250_000_000)
            await client.disconnect()
        } catch {
            // Best-effort — archive still proceeds.
            await client.disconnect()
        }
    }

    private func startSession(config: SessionConfig, title: String) {
        let session = CodeSession(
            title: title,
            repoFullName: config.repo.fullName,
            baseBranch: config.repo.baseBranch ?? "main",
            workBranch: config.repo.workBranch,
            wireSessionId: config.wireSessionId,
            environment: config.environment
        )
        sessionStore.add(session)
        // Keep selected repo in sync so other pickers stay coherent.
        if state.selectedRepo?.fullName != session.repoFullName {
            // Best-effort: leave selectedRepo alone if we only have a name.
        }
        pushSessionConfig = SessionConfig(
            id: config.id,
            wireSessionId: config.wireSessionId,
            localSessionId: session.id,
            endpoint: config.endpoint,
            token: config.token,
            repo: config.repo,
            environment: config.environment,
            model: config.model,
            permissionMode: config.permissionMode,
            firstMessage: config.firstMessage,
            skills: config.skills,
            mcpServers: config.mcpServers,
            resuming: false
        )
    }

    private func reattach(session: CodeSession) {
        // Rebuild from the persisted session — do not require the currently
        // selected repo (that blocked opening history until a new session).
        // Always open a fresh WS and send create_session with the same wire
        // id so the desktop rebinds (live) or re-clones (after restart).
        guard let endpoint = state.serverEndpoint,
              let token = state.serverToken,
              let model = state.modelSelectionForSession() else { return }
        let repoRef = RepoRef(
            fullName: session.repoFullName,
            baseBranch: session.baseBranch,
            workBranch: session.workBranch,
            githubToken: state.githubToken
        )
        sessionStore.update(session.id) { $0.status = .working }
        let config = SessionConfig(
            wireSessionId: session.wireSessionId,
            localSessionId: session.id,
            endpoint: endpoint,
            token: token,
            repo: repoRef,
            // Environment is fixed for the life of the session.
            environment: session.environment ?? state.selectedEnvironment,
            model: model,
            permissionMode: state.permissionMode,
            firstMessage: session.title,
            skills: state.skillManager.enabledSkills.map(\.content),
            mcpServers: state.mcpManager.configuredMCPServers,
            resuming: true,
            prURL: session.prURL
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

// MARK: - Archived sessions

struct ArchivedSessionsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var onOpen: (CodeSession) -> Void

    private var sessions: [CodeSession] { state.codeSessionStore.archivedSessions }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No archived sessions",
                        systemImage: "archivebox",
                        description: Text("Swipe right on a session to archive it.")
                    )
                } else {
                    List {
                        ForEach(sessions) { session in
                            Button {
                                onOpen(session)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(2)
                                    Text("\(session.repoFullName) · \(session.transcript.count) messages")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    state.codeSessionStore.remove(session.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    state.codeSessionStore.unarchive(session.id)
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(Theme.accent)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

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

extension MCPManager {
    /// Wire-format subset of the user's MCP servers. Sent to the desktop
    /// server on session create. The desktop side decides which ones to
    /// start based on transport + its own enabled flag.
    var configuredMCPServers: [MCPServerConfig] {
        // Full MCPServer wire shape (id / description / isEnabled required by desktop Zod).
        configuredServers.map { MCPServerConfig($0) }
    }
}
