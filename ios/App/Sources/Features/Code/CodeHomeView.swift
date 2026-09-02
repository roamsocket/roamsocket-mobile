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
    /// True only while the desktop agent is mid-turn (streaming / tools).
    /// Used so archive does not ask “keep running?” for idle sessions that
    /// still show a Working filter status.
    var agentActive: Bool

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
        wireSessionId: String = "s_\(UUID().uuidString.prefix(8).lowercased())",
        environment: EnvironmentConfig? = nil,
        prURL: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: Status = .working,
        toolCount: Int = 0,
        transcript: [SessionTranscriptLine] = [],
        disconnectWhenDone: Bool = false,
        agentActive: Bool = false
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
        self.agentActive = agentActive
    }

    enum CodingKeys: String, CodingKey {
        case id, title, repoFullName, baseBranch, workBranch
        case wireSessionId, environment, prURL, createdAt, updatedAt, status, toolCount
        case transcript, disconnectWhenDone, agentActive
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
        agentActive = try c.decodeIfPresent(Bool.self, forKey: .agentActive) ?? false
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

    /// Updates mid-turn agent activity without bumping `updatedAt` (list sort / relative time).
    func setAgentActive(_ id: UUID, _ active: Bool) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[idx].agentActive != active else { return }
        sessions[idx].agentActive = active
        if active, sessions[idx].status != .archived {
            sessions[idx].status = .working
        }
        objectWillChange.send()
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

    func rename(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
    }

    func saveTranscript(_ id: UUID, lines: [SessionTranscriptLine]) {
        update(id) { $0.transcript = lines }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CodeSession].self, from: data)
        else { return }
        // Agent mid-turn state does not survive process restart.
        sessions = decoded.map { session in
            var copy = session
            copy.agentActive = false
            return copy
        }
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
    var icon: String {
        switch self {
        case .acceptEdits: return "checkmark.circle"
        case .plan: return "list.bullet.clipboard"
        case .ask: return "questionmark.circle"
        }
    }
}

/// Compact git / session status pill shared by Code home and the in-session
/// commit / push / PR strip.
struct SessionGitStatusBadge: View {
    let icon: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.15), in: Capsule())
        .accessibilityLabel(label)
    }

    /// Map a persisted session status to a lightweight badge.
    static func forSessionStatus(_ status: CodeSession.Status) -> SessionGitStatusBadge {
        switch status {
        case .working:
            return SessionGitStatusBadge(
                icon: "arrow.up.circle.fill",
                label: "ahead",
                tint: Theme.accent
            )
        case .needsInput:
            return SessionGitStatusBadge(
                icon: "exclamationmark.circle.fill",
                label: "blocked",
                tint: .orange
            )
        case .readyForReview:
            return SessionGitStatusBadge(
                icon: "checkmark.circle.fill",
                label: "ready",
                tint: Theme.selection
            )
        case .completed:
            return SessionGitStatusBadge(
                icon: "checkmark.seal.fill",
                label: "merged",
                tint: Theme.textSecondary
            )
        case .archived:
            return SessionGitStatusBadge(
                icon: "archivebox.fill",
                label: "archived",
                tint: Theme.textTertiary
            )
        }
    }

    /// Live badge for an open coding session (diff / PR / agent state).
    static func live(
        isRunning: Bool,
        hasDiffs: Bool,
        hasPR: Bool,
        needsInput: Bool
    ) -> SessionGitStatusBadge {
        if needsInput {
            return forSessionStatus(.needsInput)
        }
        if hasPR {
            return SessionGitStatusBadge(
                icon: "arrow.triangle.branch",
                label: "pr open",
                tint: Theme.selection
            )
        }
        if isRunning {
            return forSessionStatus(.working)
        }
        if hasDiffs {
            return SessionGitStatusBadge(
                icon: "arrow.up.circle.fill",
                label: "ahead",
                tint: Theme.accent
            )
        }
        return SessionGitStatusBadge(
            icon: "checkmark.circle",
            label: "clean",
            tint: Theme.textSecondary
        )
    }
}

struct CodeHomeView: View {
    @EnvironmentObject var state: AppState
    @State private var statusFilter: CodeSession.Status? = nil
    @State private var showFilterSheet = false
    @State private var showEnvironmentPicker = false
    @State private var showModelPicker = false
    @State private var showNewSession = false
    @State private var showSandboxRuns = false
    @State private var showArchived = false
    /// Live coding session presented as a full-screen cover (same path as Chat).
    /// Nested `navigationDestination` under Code was unreliable: sessions never
    /// opened and toolbar actions looked dead.
    @State private var activeSessionConfig: SessionConfig?
    /// Session prepared while New Session is open — presented after that cover dismisses.
    @State private var pendingSessionConfig: SessionConfig?
    /// Session to re-open after the archived list sheet finishes dismissing.
    @State private var pendingReattachSession: CodeSession?
    @State private var archiveCandidate: CodeSession?
    @State private var showArchiveKillConfirm = false
    @State private var renameTarget: CodeSession?
    @State private var renameDraft = ""
    @State private var showServerPairing = false
    @State private var showDeviceConnectionHelp = false
    @State private var tokenWhenPairingPresented: String?
    @State private var launchError: String?

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
                // Keep the content in a flexible scroll view so the home screen
                // fills the available height instead of collapsing toward the bottom.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Devices")
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.textSecondary)
                            if state.serverName == nil && state.serverToken == nil {
                            Button {
                                presentPairingSheet()
                            } label: {
                                devicesEmpty
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .accessibilityHint("Opens pairing to connect a desktop server")
                        } else {
                            Button {
                                Task { await handleDeviceTap() }
                            } label: {
                                deviceRow(
                                    name: state.serverName ?? "Desktop",
                                    status: state.desktopReachability
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .accessibilityHint("Reconnect to the desktop server")
                        }
                    }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Sessions")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Button { showFilterSheet = true } label: {
                                    HStack(spacing: 4) {
                                        Text(statusFilter?.rawValue ?? "All")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Theme.textPrimary)
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Theme.surfaceElevated, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Filter sessions")
                            }
                            if filteredSessions.isEmpty {
                                sessionsEmpty
                        } else {
                            ForEach(filteredSessions) { session in
                                Button {
                                    Task { await reattach(session: session) }
                                } label: {
                                    sessionCard(session)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        requestArchive(session)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(Theme.accent)
                                    Button {
                                        beginRename(session)
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(Theme.textSecondary)
                                }
                                .contextMenu {
                                    Button {
                                        beginRename(session)
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Button {
                                        requestArchive(session)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    Button(role: .destructive) {
                                        sessionStore.remove(session.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 80)
                }
                .scrollIndicators(.hidden)
            }
            newSessionFAB
                .padding(.trailing, 18)
                .padding(.bottom, 22)
                .zIndex(1)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // Apply the user's code default if the current selection isn't a
            // coding-capable model (or isn't set at all). Per-chat / per-session
            // overrides already set `selectedModel` to a valid coding model and
            // are left alone. This runs synchronously so the "Pick a model"
            // hint under the start button reflects the default on first render.
            state.applyDefault(for: .code)
        }
        .task {
            // Refresh desktop reachability whenever Code home is shown.
            // Coalesces with launch reconnect via AppState.reconnectTask.
            guard state.serverToken != nil else { return }
            await state.attemptServerReconnect()
        }
        // Match Chat: present sessions in a full-screen NavigationStack so
        // toolbar / sheets / dismiss work even though Code hides its own bar.
        .fullScreenCover(item: $activeSessionConfig) { config in
            NavigationStack {
                SessionView(config: config)
            }
            .environmentObject(state)
        }
        .sheet(isPresented: $showFilterSheet) {
            SessionFilterSheet(selection: $statusFilter)
        }
        .sheet(isPresented: $showSandboxRuns) {
            SandboxesView()
                .environmentObject(state)
        }
        .sheet(isPresented: $showEnvironmentPicker) {
            EnvironmentPickerSheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(codingOnly: true)
                .environmentObject(state)
        }
        .sheet(isPresented: $showArchived, onDismiss: {
            guard let session = pendingReattachSession else { return }
            pendingReattachSession = nil
            Task { await reattach(session: session) }
        }) {
            ArchivedSessionsView { session in
                pendingReattachSession = session
                showArchived = false
            }
            .environmentObject(state)
        }
        .sheet(isPresented: $showServerPairing, onDismiss: {
            // After a successful re-pair, re-check reachability for the Devices row.
            let newToken = state.serverToken
            guard let newToken, !newToken.isEmpty, newToken != tokenWhenPairingPresented else {
                return
            }
            Task { await state.attemptServerReconnect() }
        }) {
            NavigationStack { ServerPairingView() }
                .environmentObject(state)
        }
        .sheet(isPresented: $showDeviceConnectionHelp) {
            DeviceConnectionHelpSheet {
                // Dismiss help first so the pairing sheet can present cleanly.
                showDeviceConnectionHelp = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    presentPairingSheet()
                }
            }
            .environmentObject(state)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showNewSession, onDismiss: {
            // Present the new session only after this cover is fully gone —
            // simultaneous cover + cover / nav is a common silent no-op.
            guard let pending = pendingSessionConfig else { return }
            pendingSessionConfig = nil
            DispatchQueue.main.async {
                activeSessionConfig = pending
            }
        }) {
            NewSessionView { config, task in
                pendingSessionConfig = storeNewSession(config: config, title: task)
            }
            .environmentObject(state)
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
        .alert("Rename session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
            Button("Save") {
                if let target = renameTarget {
                    sessionStore.rename(target.id, title: renameDraft)
                }
                renameTarget = nil
            }
        } message: {
            Text("Choose a short name for this coding session.")
        }
        .alert(
            "Can't open session",
            isPresented: Binding(
                get: { launchError != nil },
                set: { if !$0 { launchError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { launchError = nil }
        } message: {
            Text(launchError ?? "")
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
                    .contentShape(Circle())
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
                    .contentShape(Circle())
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
            Text("Tap to pair a desktop server on this network.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func deviceRow(name: String, status: AppState.DesktopReachability) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.selection)
                    .frame(width: 36, height: 36)
                Circle()
                    .fill(deviceStatusColor(status))
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(Theme.surface, lineWidth: 2)
                    )
                    .offset(x: 2, y: 2)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(deviceStatusSubtitle(status))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Group {
                if state.isReconnecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.textSecondary)
                } else {
                    Image(systemName: status == .connected ? "checkmark.circle" : "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(status == .connected ? Theme.selection : Theme.textSecondary)
                }
            }
            .frame(width: 36, height: 36)
            .background(Theme.surfaceElevated, in: Circle())
            .accessibilityHidden(true)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(deviceStatusSubtitle(status))")
    }

    private func deviceStatusSubtitle(_ status: AppState.DesktopReachability) -> String {
        if state.isReconnecting {
            return "Connecting…"
        }
        if status == .connected {
            return status.label
        }
        if let message = state.reconnectMessage, !message.isEmpty {
            return message
        }
        return status.label
    }

    /// Tap Devices row: reconnect, re-pair if the token is dead, otherwise
    /// open the Wi‑Fi / rescan recovery sheet.
    private func handleDeviceTap() async {
        // Unpaired (name present without token is unusual) → pair.
        if state.serverToken == nil || (state.serverToken ?? "").isEmpty {
            presentPairingSheet()
            return
        }

        // Already know the saved token was rejected — skip another probe.
        if state.needsServerRePair {
            presentPairingSheet()
            return
        }

        // Join any in-flight reconnect, or start a fresh one.
        let outcome = await state.attemptServerReconnect()
        switch outcome {
        case .connected:
            break
        case .needsRePair, .unpaired:
            presentPairingSheet()
        case .unreachable:
            showDeviceConnectionHelp = true
        }
    }

    private func presentPairingSheet() {
        tokenWhenPairingPresented = state.serverToken
        showServerPairing = true
    }

    /// Ensure the desktop is reachable before opening a coding session.
    /// Returns true when the caller may proceed with navigation.
    @discardableResult
    private func ensureDesktopConnected() async -> Bool {
        if state.serverToken == nil || (state.serverToken ?? "").isEmpty {
            presentPairingSheet()
            return false
        }
        if state.needsServerRePair {
            presentPairingSheet()
            return false
        }
        if state.desktopReachability == .connected, !state.isReconnecting {
            return true
        }
        let outcome = await state.attemptServerReconnect()
        switch outcome {
        case .connected:
            return true
        case .needsRePair, .unpaired:
            presentPairingSheet()
            return false
        case .unreachable:
            showDeviceConnectionHelp = true
            return false
        }
    }

    private func deviceStatusColor(_ status: AppState.DesktopReachability) -> Color {
        switch status {
        case .connected:
            return Color.green
        case .connecting:
            return Color.orange
        case .unreachable:
            return Color.red
        case .unpaired:
            return Theme.textTertiary
        }
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(session.workBranch)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(session.repoFullName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Relative time sits where the old "ahead"/git badge was.
            Text(relativeTime(session.updatedAt))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func beginRename(_ session: CodeSession) {
        renameTarget = session
        renameDraft = session.title
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
        HStack(spacing: 10) {
            Button {
                showSandboxRuns = true
            } label: {
                Image(systemName: "terminal.cursor.and.arrow.forward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 48, height: 48)
                    .background(Theme.surfaceElevated, in: Circle())
                    .shadow(color: .black.opacity(0.3), radius: 7, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start a run")

            Button {
                Task {
                    guard await ensureDesktopConnected() else { return }
                    showNewSession = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Start a session")
                        .font(.system(size: 15, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.accent, in: Capsule())
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start a session")
        }
    }

    // MARK: - Session lifecycle

    // MARK: - Archive / rename

    private func requestArchive(_ session: CodeSession) {
        // Only prompt when the desktop agent is actually mid-turn — not merely
        // because the row filter status is still "Working" from an earlier open.
        let live = sessionStore.session(id: session.id) ?? session
        if live.agentActive {
            archiveCandidate = live
            showArchiveKillConfirm = true
        } else {
            performArchive(live, killAgent: false)
        }
    }

    private func performArchive(_ session: CodeSession, killAgent: Bool) {
        archiveCandidate = nil
        if killAgent {
            Task { await interruptRemoteAgent(wireSessionId: session.wireSessionId) }
            sessionStore.archive(session.id, disconnectWhenDone: false)
            sessionStore.setAgentActive(session.id, false)
        } else {
            // Leave desktop work running only when it is actually mid-turn.
            let keepRunning = session.agentActive
            sessionStore.archive(session.id, disconnectWhenDone: keepRunning)
            if !keepRunning {
                sessionStore.setAgentActive(session.id, false)
            }
        }
        // If this session is open full-screen, close it so the connection policy applies.
        if activeSessionConfig?.localSessionId == session.id {
            if killAgent {
                activeSessionConfig = nil
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

    /// Persist a new session row and return the config used to open SessionView.
    /// Presentation is owned by the caller (deferred when New Session is open).
    private func storeNewSession(config: SessionConfig, title: String) -> SessionConfig {
        let session = CodeSession(
            title: title,
            repoFullName: config.repo.fullName,
            baseBranch: config.repo.baseBranch ?? "main",
            workBranch: config.repo.workBranch,
            wireSessionId: config.wireSessionId,
            environment: config.environment
        )
        sessionStore.add(session)
        return SessionConfig(
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

    private func presentSession(_ config: SessionConfig) {
        activeSessionConfig = config
    }

    private func reattach(session: CodeSession) async {
        // Rebuild from the persisted session — do not require the currently
        // selected repo (that blocked opening history until a new session).
        // Always open a fresh WS and send create_session with the same wire
        // id so the desktop rebinds (live) or re-clones (after restart).
        guard await ensureDesktopConnected() else { return }
        guard let endpoint = state.serverEndpoint, let token = state.serverToken else {
            launchError = "Pair a desktop server in Settings, then try again."
            return
        }
        guard let model = state.modelSelectionForSession() else {
            let missing = SessionLauncher.missingRequirements(in: state)
            launchError = missing.isEmpty
                ? "Pick a coding model with an API key, then open this session again."
                : missing.joined(separator: " ")
            return
        }
        let repoRef = RepoRef(
            fullName: session.repoFullName,
            baseBranch: session.baseBranch,
            workBranch: session.workBranch,
            githubToken: state.githubToken
        )
        // Re-open does not mean the agent is mid-turn yet.
        sessionStore.update(session.id) {
            $0.status = .working
            $0.agentActive = false
        }
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
        presentSession(config)
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
    @State private var renameTarget: CodeSession?
    @State private var renameDraft = ""

    private var sessions: [CodeSession] { state.codeSessionStore.archivedSessions }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No archived sessions",
                        systemImage: "archivebox",
                        description: Text("Swipe left on a session to archive it.")
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
                            .contextMenu {
                                Button {
                                    renameTarget = session
                                    renameDraft = session.title
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button {
                                    state.codeSessionStore.unarchive(session.id)
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) {
                                    state.codeSessionStore.remove(session.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
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
            .alert("Rename session", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Title", text: $renameDraft)
                Button("Cancel", role: .cancel) {
                    renameTarget = nil
                }
                Button("Save") {
                    if let target = renameTarget {
                        state.codeSessionStore.rename(target.id, title: renameDraft)
                    }
                    renameTarget = nil
                }
            }
        }
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
