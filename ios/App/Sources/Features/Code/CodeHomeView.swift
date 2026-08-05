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

/// The Code home screen: Devices (recent paired laptops), Sessions
/// (recent coding sessions with status filters), and the composer that
/// starts a new session.
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
    @State private var task: String = ""
    @State private var statusFilter: CodeSession.Status? = nil
    @State private var showFilterSheet = false
    @State private var showEnvironmentPicker = false
    @State private var showModelPicker = false
    @State private var showPlanIntake = false
    @State private var planTask: String = ""
    @State private var pushSessionConfig: SessionConfig?

    var body: some View {
        ZStack {
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
                    .padding(.bottom, 24)
                }
                composer
            }
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
        .sheet(isPresented: $showPlanIntake) {
            PlanIntakeSheet(
                task: planTask,
                onStart: { deliveryMode in
                    showPlanIntake = false
                    startSession(deliveryMode: deliveryMode)
                }
            )
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
                    Text(relativeTime(session.updatedAt))
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
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

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 10) {
            if let _ = state.selectedRepo {
                HStack {
                    Button { showEnvironmentPicker = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cloud")
                            Text(state.selectedEnvironment?.name ?? "Default")
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
            HStack(spacing: 8) {
                Button { /* TODO: file picker */ } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)

                TextField(
                    canStart ? "Code anything…" : "Pick a repo + model first",
                    text: $task,
                    axis: .vertical
                )
                .lineLimit(1...3)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))

                if state.isLoadingModels {
                    ProgressView().tint(Theme.textSecondary).frame(width: 36, height: 36)
                } else {
                    Button { showModelPicker = true } label: {
                        Text(modelPillTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button { /* TODO: accept-edits pill tap */ } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text(state.permissionMode == .acceptEdits ? "Accept edits" : state.permissionMode.displayName)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceElevated, in: Capsule())
                }
                .buttonStyle(.plain)

                Button(action: sendTapped) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(canStart ? Theme.accent : Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(Theme.background)
    }

    private var modelPillTitle: String {
        if let name = state.selectedModel?.displayName {
            return Self.stripEffort(from: name)
        }
        return "Select a model"
    }

    private static func stripEffort(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for suffix in Effort.allCases.reversed() {
            let token = " " + suffix.displayName
            if trimmed.lowercased().hasSuffix(token.lowercased()) {
                return String(trimmed.dropLast(token.count))
            }
        }
        return trimmed
    }

    private var canStart: Bool {
        state.canStartSession && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendTapped() {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Open the plan intake sheet — the user picks a delivery mode
        // before the session actually starts.
        planTask = text
        task = ""
        showPlanIntake = true
    }

    // MARK: - Session lifecycle

    private func startSession(deliveryMode: PlanIntakeSheet.DeliveryMode) {
        let text = planTask
        guard let config = SessionLauncher.makeConfig(
            in: state,
            task: PlanIntakeSheet.decorate(text: text, mode: deliveryMode)
        ) else { return }
        let session = CodeSession(
            title: text,
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

// MARK: - Plan intake sheet

struct PlanIntakeSheet: View {
    let task: String
    var onStart: (DeliveryMode) -> Void
    @Environment(\.dismiss) private var dismiss

    enum DeliveryMode: String, CaseIterable, Identifiable {
        case e2eFramework = "Set up E2E framework"
        case unitUI = "Component/unit UI tests"
        case manualRun = "Manually run & screenshot"
        case recommend = "Just explore & recommend"
        case other = "Other"

        var id: String { rawValue }

        var body: String {
            switch self {
            case .e2eFramework:
                return "Add Playwright (or similar), wire up a config + first smoke tests that load the app in a real browser, and add a CI workflow. Best for testing real user flows across the Astro island apps / PWA."
            case .unitUI:
                return "Add Vitest + React Testing Library for fast, isolated tests of React components (SiteNav, modals, portal views). Runs in jsdom, no browser."
            case .manualRun:
                return "No new test framework — just launch the app(s) with the pre-installed Chromium/Playwright and capture screenshots to verify the UI renders/works right now."
            case .recommend:
                return "Don't write code yet — audit the UI surface, propose a testing strategy and stack, and let you decide before implementing."
            case .other:
                return ""
            }
        }

        var title: String { rawValue }
    }

    @State private var selection: DeliveryMode = .e2eFramework
    @State private var customText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("<")
                        Text("1 of \(DeliveryMode.allCases.count - 1)")
                        Spacer()
                        Text(">")
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 8)

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What do you want \"\(task)\" to deliver?")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(DeliveryMode.allCases.filter { $0 != .other }) { mode in
                        Button {
                            selection = mode
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(mode.body)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textSecondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selection == mode ? Theme.selection : Color.clear, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Text("Other")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 8)
                    TextField("", text: $customText, prompt: Text("Describe a custom delivery mode").foregroundColor(Theme.textTertiary))
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))

                    HStack {
                        Spacer()
                        Button {
                            if selection == .other {
                                onStart(.other)
                            } else {
                                onStart(selection)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.right")
                                Text("Next")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Theme.textPrimary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .background(Theme.background)
            .presentationDetents([.large])
        }
        .preferredColorScheme(.dark)
    }

    static func decorate(text: String, mode: DeliveryMode) -> String {
        // The session's first message leads with the delivery context so
        // the agent knows what shape of answer to produce.
        switch mode {
        case .e2eFramework:
            return "E2E framework (Playwright + CI): \(text)"
        case .unitUI:
            return "Component/unit UI tests (Vitest + RTL): \(text)"
        case .manualRun:
            return "Manual run + screenshots: \(text)"
        case .recommend:
            return "Audit + recommend only (no code): \(text)"
        case .other:
            return text
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
