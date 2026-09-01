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

/// The Code home screen on iOS. Two paths live here, side by side:
///   - **Phone sandbox (E2B)**: the default. Pick a repo, run a
///     command on a fresh e2b.dev sandbox. The sandbox is a
///     one-shot: clone → install → run. History persists.
///   - **Desktop session**: the full agent loop. Requires a
///     paired desktop running the server (the existing path
///     that drives `SessionView` / `SessionViewModel`). The
///     phone is a thin client; the desktop does the work.
///
/// Both paths land in a chat-style session UI. The phone sandbox
/// path is currently one-shot (no agent loop on the phone); the
/// desktop path has the full agent. Bridging the two — running
/// the agent loop on the phone by orchestrating the E2B sandbox
/// — is the next phase. Until then, the desktop path is the way
/// to get AI-driven multi-step code changes.
struct CodeHomeView: View {
    @EnvironmentObject var state: AppState
    /// Drives the "Start a run" sheet (repo / branch / preset / command).
    @State private var showStartSheet = false
    /// Inline error from the start sheet (missing key, sandbox create
    /// failed, etc.) — surfaces as an alert above the run history.
    @State private var startError: String?
    /// Desktop session launched from this screen, if any. When
    /// non-nil, `SessionView` is presented as a fullScreenCover.
    @State private var desktopSession: SessionConfig?
    /// Sheet for the desktop pairing flow. Independent of the
    /// Settings card so the user can pair without leaving Code.
    @State private var showPairing = false

    /// Opens the root sidebar drawer. Wired from `RootView` so Code can open
    /// the same destinations as Chat even though this screen hides the
    /// system navigation bar.
    var onOpenSidebar: () -> Void = {}

    /// Per-screen store for the phone-originated runs. Lifted out of
    /// `@StateObject` so the screen is cheap to recreate; the
    /// persisted history survives via `PhoneRunPersistence`.
    @StateObject private var store = SandboxesStore()

    private var isPaired: Bool {
        state.serverToken != nil && (state.serverName?.isEmpty == false)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Path 1: desktop session. The full agent
                        // loop path — only shown when the user has
                        // paired a desktop. Tap → open a new
                        // session (or resume the most recent) →
                        // SessionView fullScreenCover.
                        if isPaired {
                            desktopCard
                        } else {
                            pairDesktopCard
                        }
                        // Path 2: phone sandbox (E2B). Always
                        // shown. This is the default path.
                        e2bSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            // Floating "Start a run" affordance. Disabled until the
            // user has an e2b key; the empty state surfaces the
            // "Add your e2b.dev key" CTA in that case.
            VStack {
                Spacer()
                Button {
                    showStartSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Start a run")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(state.e2bKeyStore.hasKey ? Theme.accent : Theme.textTertiary,
                                in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!state.e2bKeyStore.hasKey)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSidebar) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open sidebar")
            }
        }
        .sheet(isPresented: $showStartSheet) {
            StartRunSheet(onStart: { req in startRun(req) })
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showPairing) {
            NavigationStack { ServerPairingView() }
                .environmentObject(state)
        }
        .fullScreenCover(item: $desktopSession) { config in
            NavigationStack { SessionView(config: config) }
                .environmentObject(state)
        }
        .alert("Run error", isPresented: Binding(
            get: { startError != nil },
            set: { if !$0 { startError = nil } }
        )) {
            Button("OK", role: .cancel) { startError = nil }
        } message: {
            Text(startError ?? "")
        }
    }

    private var rows: [RunRow] {
        state.sandboxesStore.phoneRuns.map { run in
            RunRow(
                id: run.id,
                repoFullName: run.repoFullName,
                branch: run.branch,
                status: run.status,
                exitCode: run.exitCode,
                sandboxUrl: run.sandboxUrl,
                command: run.command,
                outputTail: run.outputTail,
                error: run.error,
                startedAt: run.startedAt,
                steps: run.steps,
            )
        }
    }

    private func startRun(_ req: E2bPhoneRunRequest) {
        guard let apiKey = state.e2bKeyStore.get(), !apiKey.isEmpty else {
            // Belt-and-braces: the FAB is disabled when there's no key,
            // but if the user reaches this path via a deep link or a
            // paste from elsewhere, route them to the key sheet.
            state.showE2BKeySheet = true
            return
        }
        state.sandboxesStore.startPhoneRun(
            apiKey: apiKey,
            githubToken: state.githubToken,
            request: req,
        )
        showStartSheet = false
    }

    /// Re-run a finished run with the same repo + branch + command.
    /// `E2bPhoneRun` doesn't currently persist the install
    /// command or the original `E2bPhoneRepoSelection` (just the
    /// display name), so the re-run skips the install step and
    /// infers GitHub vs URL from the display name. For a URL repo
    /// the re-run will still work — the URL is reconstructed from
    /// the `owner/repo` shape — but for non-GitHub URLs the user
    /// is better off re-running from the start sheet.
    private func rerun(row: RunRow) {
        guard let apiKey = state.e2bKeyStore.get(), !apiKey.isEmpty else {
            startError = "Add your e2b.dev API key in Settings first."
            return
        }
        let repo = inferRepoSelection(from: row.repoFullName)
        let req = E2bPhoneRunRequest(
            repo: repo,
            branch: row.branch,
            command: row.command,
            installCommand: nil, // not persisted; user can re-add via start sheet
            githubToken: state.githubToken,
            preset: nil,
        )
        state.sandboxesStore.startPhoneRun(
            apiKey: apiKey,
            githubToken: state.githubToken,
            request: req,
        )
    }

    /// Best-effort repo selection inference from the display name.
    /// If it starts with `http://` or `https://` it's a URL; else
    /// treat it as `owner/repo` for GitHub. This handles the common
    /// case (a GitHub `owner/repo` re-run) and the URL case for
    /// paste-style runs.
    private func inferRepoSelection(from displayName: String) -> E2bPhoneRepoSelection {
        if displayName.hasPrefix("http://") || displayName.hasPrefix("https://") {
            return .url(displayName)
        }
        return .github(fullName: displayName)
    }

    // MARK: - Sections

    /// E2B sandboxes section. Pinned active run + history, or the
    /// empty state if there are no runs yet.
    @ViewBuilder
    private var e2bSection: some View {
        if rows.isEmpty {
            CodeEmptyState(
                hasPhoneKey: state.e2bKeyStore.hasKey,
                onStart: { showStartSheet = true },
                onAddKey: { state.showE2BKeySheet = true },
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        } else {
            let active = rows.first(where: { $0.status == "running" || $0.status == "queued" })
            let past = rows.filter { $0.status != "running" && $0.status != "queued" }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text("Phone sandbox")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(.uppercase)
                    Spacer()
                    Button {
                        showStartSheet = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Start")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                if let active {
                    RunRowView(row: active, onStop: {
                        state.sandboxesStore.cancelPhoneRun(runId: active.id)
                    }, onRerun: { rerun(row: active) })
                }
                if !past.isEmpty {
                    Text("History")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                    ForEach(past) { row in
                        RunRowView(row: row, onStop: {
                            state.sandboxesStore.cancelPhoneRun(runId: row.id)
                        }, onRerun: { rerun(row: row) })
                    }
                }
            }
        }
    }

    /// Card shown when a desktop is paired. Offers the full
    /// agent-loop path: open a new session on the desktop, which
    /// drives the existing `SessionView` fullScreenCover.
    private var desktopCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.serverName ?? "Desktop")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(desktopSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    launchDesktopSession()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Start desktop session")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canLaunchDesktop)
                .opacity(canLaunchDesktop ? 1 : 0.5)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.separator.opacity(0.6), lineWidth: 1)
        )
    }

    /// Card shown when no desktop is paired. Directs the user to
    /// the pairing flow (also reachable from Settings).
    private var pairDesktopCard: some View {
        Button {
            showPairing = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair a desktop for the full agent loop")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Phone sandboxes run one command. A paired desktop adds AI-driven multi-step edits, git, and PRs.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.separator.opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var desktopSubtitle: String {
        let status = state.desktopReachability
        switch status {
        case .connected: return "Connected · start a session to drive the agent loop."
        case .connecting: return "Connecting…"
        case .unreachable: return "Unreachable — try pairing again."
        case .unpaired: return "Paired · ready."
        }
    }

    /// Prerequisite check for launching a desktop session. Mirrors
    /// the desktop's pre-session checks: repo selected, model with
    /// API key, and the desktop actually reachable.
    private var canLaunchDesktop: Bool {
        guard state.desktopReachability == .connected else { return false }
        guard state.selectedRepo != nil else { return false }
        guard let model = state.selectedModel else { return false }
        return !state.resolvedAPIKey(for: model.provider).isEmpty
    }

    /// Build a `SessionConfig` and trigger the desktop-session cover.
    /// Surfaces a friendly error if the prerequisites aren't met.
    private func launchDesktopSession() {
        let missing = SessionLauncher.missingRequirements(in: state)
        if !missing.isEmpty {
            startError = missing.joined(separator: " ")
            return
        }
        guard let config = SessionLauncher.makeConfig(in: state, task: "Start a new coding session.") else {
            startError = "Couldn't build a session config. Check pairing + repo + API key."
            return
        }
        desktopSession = config
    }
}

// MARK: - Code-home empty state

/// Code-home variant of the Sandboxes empty state. Adds the
/// "Add your e2b.dev key" CTA when the user has no key set, so
/// the Code tab is usable from cold start (no Settings round-trip
/// required to discover the key).
private struct CodeEmptyState: View {
    let hasPhoneKey: Bool
    let onStart: () -> Void
    let onAddKey: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Run code on a phone sandbox")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(hasPhoneKey
                 ? "Tap Start a run to spin up a fresh e2b sandbox and run a command on your repo."
                 : "Add your e2b.dev API key, then tap Start a run to spin up a fresh e2b sandbox.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if hasPhoneKey {
                Button(action: onStart) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Start a run")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onAddKey) {
                    HStack(spacing: 6) {
                        Image(systemName: "key")
                        Text("Add your e2b.dev API key")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
