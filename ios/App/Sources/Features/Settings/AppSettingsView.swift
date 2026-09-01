import SwiftUI
import AnyProvCore

/// App settings sheet. Every row is wired to a real configuration destination.
/// The full legacy form lives behind "Advanced settings".
struct AppSettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showGitHubLink = false
    @State private var showServerPair = false
    @State private var showSkills = false
    @State private var showMCP = false
    @State private var showMarketplace = false
    @State private var showMemory = false
    @State private var showSandboxes = false
    @State private var showAbout = false
    @State private var showProviderKeys = false
    @State private var showLocalMetal = false
    @State private var showVoiceSettings = false
    @State private var defaultModelKind: AppState.DefaultModelKind?
    @State private var syncInFlight = false
    @State private var syncMessage: String?
    @State private var syncError: String?
    @State private var pendingPullSnapshot: AppSettingsSnapshot?
    /// Per-kind status from the last push/pull, shown as bullets under the
    /// main button. Empty when no sync has run yet.
    @State private var syncStatuses: [SettingsSync.SyncKind: String] = [:]

    /// Optional entry focus. `.providers` jumps straight into the API-key
    /// providers screen as soon as the settings sheet finishes presenting,
    /// which is what the model-selector pill uses when the user has no
    /// usable model yet. Defaults to nil so the home-screen entry keeps
    /// landing on the main settings page.
    var initialFocus: SettingsFocus? = nil
    @State private var autoOpenedFocus: Bool = false

    init(initialFocus: SettingsFocus? = nil) {
        self.initialFocus = initialFocus
    }

    enum SettingsFocus: String, Hashable {
        case providers
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 16) {
                        quickAccessSection
                        accountSection
                        desktopServerSection
                        sandboxesSection
                        defaultModelSection
                        appearanceSection
                        chatSection
                        effortSection
                        codingSection
                        shortcutsSection
                        settingsBackupSection
                        marketplaceSection
                        skillsSection
                        mcpSection
                        memorySection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .task {
            // Pull the latest skills + MCP from the desktop every time the
            // settings sheet appears. The server's replies are applied to the
            // local caches and the SkillManager / MCPManager.
            if state.serverToken != nil {
                await state.refreshSkillsAndMCP()
            }
            // Honor the caller's entry focus on first presentation only,
            // so re-opens don't keep shoving the user back into the
            // providers screen.
            if !autoOpenedFocus, initialFocus == .providers {
                autoOpenedFocus = true
                showProviderKeys = true
            }
        }
        .sheet(isPresented: $showGitHubLink) {
            NavigationStack { GitHubLinkView() }
        }
        .sheet(isPresented: $showServerPair) {
            NavigationStack { ServerPairingView() }
        }
        .sheet(isPresented: $showSkills) {
            InstalledSkillsView()
        }
        .sheet(isPresented: $showMarketplace) {
            MarketplaceSettingsView()
        }
        .sheet(isPresented: $showMCP) {
            ConnectorManagerView()
        }
        .sheet(isPresented: $showMemory) {
            ManageMemoryView()
                .environmentObject(state)
        }
        // NOTE: the Sandboxes sheet and the E2B key entry sheet
        // are no longer attached here. Both moved to RootView so
        // they can be opened from any surface (sidebar, unpaired
        // Code home, etc.) without Settings being open first. The
        // flags live on `state.showSandboxes` and
        // `state.showE2BKeySheet`; the views below flip them on
        // tap.
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
        .sheet(isPresented: $showProviderKeys) {
            ProviderKeysView()
        }
        .sheet(isPresented: $showLocalMetal) {
            LocalMetalSettingsView()
        }
        .sheet(isPresented: $showVoiceSettings) {
            VoiceSettingsView()
                .environmentObject(state)
        }
        .sheet(item: $defaultModelKind) { kind in
            // Default model picker for one lane. The sheet resolves the stored
            // id, lets the user pick a new model (writes the new id on tap),
            // offers "Use currently selected model", and "Clear default".
            DefaultModelSheet(kind: kind)
                .environmentObject(state)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Settings")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button(action: { showAbout = true }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Account

    // MARK: - Quick access (Git / E2B / AI management)

    /// Three large tappable cards at the top of Settings that
    /// surface the most important entry points: Git, Sandboxes
    /// (E2B), and AI management. Each card summarises the area's
    /// current state and opens the relevant sub-screen on tap.
    ///
    /// Scoping:
    ///   - Git + AI management cards are always shown.
    ///   - The E2B card is always shown too, but its tap target
    ///     and "status" subtitle gate the deeper flows — phone-
    ///     originated runs are exclusive to having an e2b key
    ///     (or a paired desktop with an admin key). The card text
    ///     surfaces the current state so the user knows which
    ///     path is available before they tap.
    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick access")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                QuickAccessCard(
                    systemImage: "link",
                    title: "Git",
                    subtitle: "Repos, commits, branches",
                    statusLabel: githubStatus,
                    isReady: !((state.githubToken ?? "").isEmpty),
                    action: { showGitHubLink = true },
                )
                Divider().background(Theme.separator)
                QuickAccessCard(
                    systemImage: "shippingbox",
                    title: "E2B",
                    subtitle: e2bQuickAccessSubtitle,
                    statusLabel: e2bQuickAccessStatus,
                    isReady: e2bQuickAccessIsReady,
                    action: {
                        // Phone-only: open the Sandboxes sheet when a
                        // key is set, otherwise prompt the user to
                        // paste one. The desktop is no longer in
                        // this flow.
                        if !(state.e2bKeyStore.get() ?? "").isEmpty {
                            showSandboxes = true
                        } else {
                            state.showE2BKeySheet = true
                        }
                    },
                )
                Divider().background(Theme.separator)
                QuickAccessCard(
                    systemImage: "brain",
                    title: "AI management",
                    subtitle: "Default model · providers · effort",
                    statusLabel: providerKeysStatus,
                    isReady: true,
                    action: { showProviderKeys = true },
                )
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private var e2bQuickAccessSubtitle: String {
        // Phone-only — desktop-mediated runs are gone. The status
        // reflects whether the key is set, and (if the user has
        // verified) whether the key actually works.
        if !(state.e2bKeyStore.get() ?? "").isEmpty { return "Run code on e2b sandboxes from this device." }
        return "Add your e2b.dev key to run from this device."
    }

    private var e2bQuickAccessStatus: String {
        if !(state.e2bKeyStore.get() ?? "").isEmpty { return "Ready" }
        return "Setup"
    }

    /// True when the user can actually start a run from the E2B
    /// card. Phone-only: just need a key set. Drives the card's
    /// `Setup` / `Ready` styling.
    private var e2bQuickAccessIsReady: Bool {
        !(state.e2bKeyStore.get() ?? "").isEmpty
    }

    /// GitHub link status + provider API keys. Replaces the old fake
    /// "Profile / Billing / Usage / Notifications / Privacy / Shared links"
    /// block — those were dead-ended menu items.
    private var accountSection: some View {
        settingsCard(header: "Account") {
            Button {
                showGitHubLink = true
            } label: {
                row(
                    systemImage: "link",
                    title: "GitHub",
                    trailing: githubStatus
                )
            }
            .buttonStyle(.plain)

            Divider().background(Theme.separator)

            Button {
                showProviderKeys = true
            } label: {
                row(
                    systemImage: "key.fill",
                    title: "Provider API keys",
                    trailing: providerKeysStatus
                )
            }
            .buttonStyle(.plain)

            Divider().background(Theme.separator)

            Button {
                showLocalMetal = true
            } label: {
                row(
                    systemImage: "cpu",
                    title: "Manage models (Metal)",
                    trailing: "Chat only"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var githubStatus: String {
        state.githubToken?.isEmpty == false ? "Linked" : "Not linked"
    }

    /// Built-in providers with a stored key, plus every custom provider
    /// (custom hosts count even when the key is blank — Ollama-style).
    private var providerKeysStatus: String {
        let builtIn = ProviderID.allBuiltInCases
            .filter { $0.requiresAPIKey && !state.apiKey(for: $0).isEmpty }
            .count
        let count = builtIn + state.customProviders.count
        if count == 0 { return "Add +" }
        return count == 1 ? "1 provider" : "\(count) providers"
    }

    // MARK: - Desktop server

    /// Standalone "Desktop server" section. Shows a colored status dot
    /// + the simplified `Paired` / `Not paired` label. Pulled out of
    /// the old `Coding` block so it can sit directly above the
    /// Sandboxes (E2B) section — they're related (sandbox runs can be
    /// desktop-mediated or phone-originated).
    private var desktopServerSection: some View {
        settingsCard(header: "Desktop server") {
            Button {
                showServerPair = true
            } label: {
                HStack(spacing: 14) {
                    DesktopStatusDot(color: desktopStatusColor)
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.serverToken == nil ? "Not paired" : "Paired")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Theme.textPrimary)
                        Text(serverStatusSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let msg = state.reconnectMessage, !msg.isEmpty {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    /// Resolves the current pairing + reachability to a dot colour.
    ///   - grey   = no token
    ///   - yellow = actively reconnecting / connecting
    ///   - green  = last known reachable
    ///   - red    = last attempt said unreachable
    private var desktopStatusColor: Color {
        if state.serverToken == nil { return Color(white: 0.55) }
        if state.isReconnecting { return .yellow }
        switch state.desktopReachability {
        case .unpaired: return Color(white: 0.55)
        case .connecting: return .yellow
        case .connected: return .green
        case .unreachable: return .red
        }
    }

    /// One-line subtitle under the Paired / Not paired label. The
    /// server name still shows up here (just not next to the chevron)
    /// plus a connecting / unreachable hint.
    private var serverStatusSubtitle: String {
        if state.isReconnecting { return "Reconnecting…" }
        if state.desktopReachability == .unreachable {
            return "Last seen: unreachable"
        }
        if let name = state.serverName, !name.isEmpty { return name }
        if state.serverToken != nil { return "Tap to manage" }
        return "Tap to pair a desktop for coding sessions."
    }

    // MARK: - Coding

    /// Coding-session settings that aren't about pairing: branch
    /// prefix, etc. Desktop-server pairing lives in its own section
    /// directly above Sandboxes now.
    private var codingSection: some View {
        settingsCard(header: "Coding") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Branch prefix")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("Each coding session gets its own branch: \(previewBranchExample)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("roamsocket", text: $state.codeBranchPrefix)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
    }

    private var previewBranchExample: String {
        let p = state.codeBranchPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = p.isEmpty ? "roamsocket" : p
        return "\(prefix)/your-task-a1b2c3d4"
    }

    // MARK: - Shortcuts & system controls

    /// Documents how to pin Chat / Code / Vision to Action Button, Control
    /// Center, Lock Screen, and Shortcuts. The intents themselves are registered
    /// via `RoamSocketShortcutsProvider`.
    private var shortcutsSection: some View {
        settingsCard(header: "Shortcuts") {
            VStack(alignment: .leading, spacing: 12) {
                shortcutRow(
                    systemImage: "bubble.left.and.bubble.right.fill",
                    title: "Chat",
                    subtitle: "Open the chat composer"
                )
                Divider().background(Theme.separator)
                shortcutRow(
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    title: "Code",
                    subtitle: "Open coding sessions"
                )
                Divider().background(Theme.separator)
                shortcutRow(
                    systemImage: "eye.fill",
                    title: "Vision",
                    subtitle: "Open camera analysis"
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("How to use")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    shortcutHowTo(
                        "Action Button",
                        "Settings → Action Button → Shortcut → pick Chat, Code, or Vision."
                    )
                    shortcutHowTo(
                        "Control Center",
                        "Open Control Center → Edit Controls → add Chat, Code, or Vision."
                    )
                    shortcutHowTo(
                        "Lock Screen",
                        "Long-press Lock Screen → Customize → add a control → pick RoamSocket."
                    )
                    shortcutHowTo(
                        "Shortcuts app",
                        "Search RoamSocket to run Chat, Code, or Vision from automations."
                    )
                    Text("While a long reply is in progress, a Live Activity shows on the Lock Screen and Dynamic Island.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func shortcutRow(systemImage: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func shortcutHowTo(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Default model per lane

    /// Lets the user pin a separate default model for chat, code, vision, and
    /// lightweight helper generations. Each row opens `DefaultModelSheet`
    /// scoped to that lane's provider pool (chat: all providers, code:
    /// coding-agent only, vision: vision-capable, lightweight: chat providers
    /// plus Apple Intelligence as a special "no-id" option).
    private var defaultModelSection: some View {
        settingsCard(header: "Default model") {
            ForEach(Array(AppState.DefaultModelKind.allCases.enumerated()), id: \.element.id) { idx, kind in
                Button {
                    defaultModelKind = kind
                } label: {
                    defaultModelRow(kind: kind)
                }
                .buttonStyle(.plain)
                if idx < AppState.DefaultModelKind.allCases.count - 1 {
                    Divider().background(Theme.separator)
                }
            }
        }
    }

    private func defaultModelRow(kind: AppState.DefaultModelKind) -> some View {
        HStack(spacing: 14) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(defaultModelSubtitle(for: kind))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(defaultModelTrailing(for: kind))
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// One-line subtitle for the default row: short label when set, hint copy
    /// when not set so the row reads as actionable.
    private func defaultModelSubtitle(for kind: AppState.DefaultModelKind) -> String {
        switch kind {
        case .chat:       return "Used when you start a new chat"
        case .code:       return "Used when you open Code"
        case .vision:     return "Used when you open Vision"
        case .lightweight: return "Used for short helper jobs (titles, summaries, commit messages)"
        }
    }

    /// Trailing value for the default row: friendly name when a valid default
    /// exists, "Not set" when there's no usable pick, "Unavailable" when the
    /// stored id no longer resolves (e.g. provider key removed, model hidden).
    private func defaultModelTrailing(for kind: AppState.DefaultModelKind) -> String {
        if let name = state.defaultModelDisplayName(for: kind) { return name }
        if state.defaultModelID(for: kind).isEmpty { return "Not set" }
        return "Unavailable"
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        settingsCard(header: "Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                ThemeSegmentedControl(
                    options: AppAppearance.allCases.map { ($0, $0.title) },
                    selection: appearanceBinding
                )
                .accessibilityLabel("Appearance")

                Text(state.appearance.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { state.appearance },
            set: { state.appearance = $0 }
        )
    }

    // MARK: - Chat (thinking display)

    private var chatSection: some View {
        settingsCard(header: "Chat") {
            ToggleRow(
                systemImage: "brain.head.profile",
                title: "Always expand thinking",
                subtitle: "Show full reasoning under the summary row (tap still opens Thought process).",
                iconColor: Theme.accent,
                isOn: $state.alwaysExpandThinking
            )

            Divider().background(Theme.separator)

            Button {
                showVoiceSettings = true
            } label: {
                row(
                    systemImage: "waveform",
                    title: "Voice chat",
                    trailing: voiceSettingsTrailing
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var voiceSettingsTrailing: String {
        let store = VoiceSettingsStore.shared
        let credentials = VoiceTTSCredentials(
            openAIKey: state.apiKey(for: .openai),
            elevenLabsKey: state.voiceAPIKey(for: VoiceSettingsStore.elevenLabsVoiceKeyID)
        )
        return store.statusLabel(credentials: credentials)
    }

    // MARK: - Effort (Claude-style explanations)

    private var effortSection: some View {
        settingsCard(header: "Effort") {
            EffortControl(effort: $state.effort)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }

    // MARK: - Memory (submenu entry; full UI in ManageMemoryView)

    private var memorySection: some View {
        settingsCard(header: "Memory") {
            Button {
                showMemory = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 28)
                    Text("Manage memory")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    let count = UserMemoryStore.shared.list().count
                    if count > 0 {
                        Text("\(count) saved")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Sandboxes (E2B)

    /// E2B sandbox runs. The desktop server kicks off a sandbox after every
    /// successful git push (the auto-trigger) and streams the output back
    /// over the same WS. The user can also start runs directly from the
    /// phone using their own e2b.dev API key (entered via the E2B API
    /// key row below) — that's the "no PC" path.
    private var sandboxesSection: some View {
        settingsCard(header: "Sandboxes (E2B)") {
            VStack(spacing: 0) {
                Button {
                    showSandboxes = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("E2B runs")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Run pushed branches in a clean E2B sandbox.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().background(Theme.separator)

                Button {
                    state.showE2BKeySheet = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: state.e2bKeyStore.hasKey ? "key.fill" : "key")
                            .font(.system(size: 20))
                            .foregroundStyle(state.e2bKeyStore.hasKey ? Theme.accent : Theme.textPrimary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("E2B API key")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(Theme.textPrimary)
                            Text(state.e2bKeyStore.hasKey
                                 ? "Your key is set — sandboxes can run from this device."
                                 : "Add your e2b.dev key to run sandboxes from your phone.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(state.e2bKeyStore.hasKey ? "Set" : "Not set")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Whether the user has entered their personal e2b.dev key on
    /// this device. Used by the Sandboxes card to label the E2B API
    /// key row and by the Sandboxes view to gate the "Start a run"
    /// flow when no desktop is paired.
    private var e2bKeyHasValue: Bool { state.e2bKeyStore.hasKey }

    // MARK: - Settings backup

    /// GitHub-backed settings sync. The app auto-creates
    /// `anyprov-code-settings` under the user's account on the first push.
    private var settingsBackupSection: some View {
        settingsCard(header: "Settings backup") {
            VStack(alignment: .leading, spacing: 12) {
                Text(settingsBackupBlurb)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                Button(action: pushSettings) {
                    HStack(spacing: 10) {
                        if syncInFlight {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up.doc.on.clipboard")
                        }
                        Text(syncButtonTitle)
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.textPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(syncInFlight)
                .padding(.horizontal, 16)

                if let syncMessage {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 16)
                }
                if !syncStatuses.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(SettingsSync.SyncKind.allCases, id: \.self) { kind in
                            if let line = syncStatuses[kind] {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(kind.displayName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.textSecondary)
                                    Text(line)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                if let syncError {
                    Text(syncError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }

                Divider().background(Theme.separator)
                Button {
                    pullSettings()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.doc")
                        Text("Restore from GitHub")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(syncInFlight)
            }
            .padding(.vertical, 12)
        }
        .alert(
            "Apply settings from GitHub?",
            isPresented: Binding(
                get: { pendingPullSnapshot != nil },
                set: { if !$0 { pendingPullSnapshot = nil } }
            ),
            presenting: pendingPullSnapshot
        ) { _ in
            Button("Apply", role: .destructive) {
                if let snap = pendingPullSnapshot {
                    state.applySnapshot(snap)
                    syncMessage = "Restored from GitHub."
                    pendingPullSnapshot = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingPullSnapshot = nil }
        } message: { snap in
            Text("GitHub snapshot has \(snap.environments.count) environment(s), \(snap.customProviders.count) custom provider(s), \(snap.modelAliases.count) model alias(es), and \(snap.hiddenModels.count) hidden model(s).")
        }
    }

    private var settingsBackupBlurb: String {
        if let repo = state.settingsSyncRepoFullName {
            return "Settings, memory, and chat history (no incognito) are stored in \(repo). Add a new device and restore from GitHub to get the same environments, model aliases, memory entries, and chats."
        }
        return "We'll create a private \(SettingsSync.repoName) repo in your account and push your settings, memory, and non-incognito chat history there."
    }

    private var syncButtonTitle: String {
        state.settingsSyncRepoFullName == nil ? "Sync to GitHub" : "Push to GitHub"
    }

    /// Push settings + memory + chats to the private sync repo. Each kind
    /// gets its own status line so the user can see what made it. Memory
    /// and chats fall back to an empty payload if the in-app store hasn't
    /// loaded yet (very early in launch).
    private func pushSettings() {
        guard let token = state.githubToken, !token.isEmpty else {
            syncError = nil
            showGitHubLink = true
            return
        }
        syncInFlight = true
        syncError = nil
        syncMessage = nil
        syncStatuses = [:]
        Task { @MainActor in
            do {
                let repo = try await state.settingsSync.ensureRepo(token: token)
                state.settingsSyncRepoFullName = repo.fullName

                // 1. Settings.
                let settingsSnap = state.snapshotForSync()
                try await state.settingsSync.push(
                    snapshot: settingsSnap,
                    token: token,
                    repoFullName: repo.fullName
                )
                syncStatuses[.settings] = "Pushed."

                // 2. Memory.
                let memorySnap = state.memorySnapshotForSync()
                try await state.settingsSync.push(
                    memory: memorySnap,
                    token: token,
                    repoFullName: repo.fullName
                )
                syncStatuses[.memory] = "\(memorySnap.entries.count) entries."

                // 3. Chats.
                if let chatsSnap = state.chatsSnapshotForSync() {
                    try await state.settingsSync.push(
                        chats: chatsSnap,
                        token: token,
                        repoFullName: repo.fullName
                    )
                    let recentCount = chatsSnap.recents.count
                    let projectCount = chatsSnap.projects.count
                    let projectChatCount = chatsSnap.projectChats
                        .reduce(0) { $0 + $1.value.count }
                    syncStatuses[.recents] = "\(recentCount) chat(s)."
                    syncStatuses[.projects] = "\(projectCount) project(s)."
                    syncStatuses[.projectChats] = "\(projectChatCount) chat(s) across projects."
                } else {
                    for kind in [SettingsSync.SyncKind.recents,
                                 .projects, .projectChats] {
                        syncStatuses[kind] = "Skipped (history not loaded)."
                    }
                }

                syncMessage = "Pushed to \(repo.fullName)."
            } catch {
                syncError = error.localizedDescription
            }
            syncInFlight = false
        }
    }

    /// Pull all three kinds. Memory and chats merge silently; settings
    /// still prompts for confirmation since applying them clobbers state.
    private func pullSettings() {
        guard let token = state.githubToken, !token.isEmpty else {
            syncError = nil
            showGitHubLink = true
            return
        }
        syncInFlight = true
        syncError = nil
        syncMessage = nil
        syncStatuses = [:]
        Task { @MainActor in
            do {
                let repo = try await state.settingsSync.ensureRepo(token: token)
                state.settingsSyncRepoFullName = repo.fullName

                // Settings — surface the "Apply?" dialog.
                if let snap = try await state.settingsSync.pull(
                    token: token,
                    repoFullName: repo.fullName
                ) {
                    pendingPullSnapshot = snap
                    syncStatuses[.settings] = "Ready to apply."
                } else {
                    syncStatuses[.settings] = "Not found in repo."
                }

                // Memory — merge silently.
                if let mem = try await state.settingsSync.pullMemory(
                    token: token,
                    repoFullName: repo.fullName
                ) {
                    state.applyMemorySnapshot(mem)
                    syncStatuses[.memory] = "Merged \(mem.entries.count) entries."
                } else {
                    syncStatuses[.memory] = "Not found in repo."
                }

                // Chats — merge silently.
                let chats = try await state.settingsSync.pullChats(
                    token: token,
                    repoFullName: repo.fullName
                )
                let totalRecents = chats.recents.count
                let totalProjects = chats.projects.count
                let totalProjectChats = chats.projectChats
                    .reduce(0) { $0 + $1.value.count }
                let merged = state.applyChatsSnapshot(chats)
                if merged || totalRecents + totalProjects + totalProjectChats > 0 {
                    syncStatuses[.recents] = "Merged \(totalRecents) chat(s)."
                    syncStatuses[.projects] = "Merged \(totalProjects) project(s)."
                    syncStatuses[.projectChats] = "Merged \(totalProjectChats) project chat(s)."
                } else {
                    syncStatuses[.recents] = "Nothing in repo."
                    syncStatuses[.projects] = "Nothing in repo."
                    syncStatuses[.projectChats] = "Nothing in repo."
                }

                syncMessage = "Pulled from \(repo.fullName)."
            } catch {
                syncError = error.localizedDescription
            }
            syncInFlight = false
        }
    }

    // MARK: - Marketplace

    private var marketplaceSection: some View {
        settingsCard(header: "Marketplace") {
            Button {
                showMarketplace = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "storefront")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manage repositories")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Official catalog + your GitHub marketplace repos")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Skills

    /// Skills + connectors are synced from git repos on the user's GitHub
    /// account. The actual git operations happen on the desktop; this
    /// section just stores the repo URLs/branches and tells the user to
    /// configure them on the desktop side too.
    private var syncSection: some View {
        settingsCard(header: "Sync") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Skills & connectors are pulled from git repos on your GitHub account. Configure the URLs in the desktop app or via environment variables:")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("APC_SKILLS_REPO / APC_MCP_REPO")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    Text("APC_SKILLS_BRANCH / APC_MCP_BRANCH (default main)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    Text("APC_SKILLS_TOKEN / APC_MCP_TOKEN (optional GitHub PAT)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var skillsSection: some View {
        settingsCard(header: "Skills") {
            Button {
                showSkills = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 28)
                    Text("Manage skills")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    let count = state.skillManager.installedSkills.count
                    if count > 0 {
                        Text("\(count) installed")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - MCP

    private var mcpSection: some View {
        settingsCard(header: "Connectors") {
            Button {
                showMCP = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 28)
                    Text("Manage connectors")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    let count = state.mcpManager.configuredServers.count
                    if count > 0 {
                        Text("\(count) configured")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingsCard<Content: View>(header: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(header)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    @ViewBuilder
    private func row(systemImage: String, title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 28)
            Text(title)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - Provider Keys sheet

/// Quick view of provider API keys (one sheet to look at and edit them from
/// app settings).
/// this is the abbreviated entry.
private struct ProviderKeysView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showAddCustom = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ProviderID.allCases.filter(\.requiresAPIKey)) { provider in
                        ProviderKeyRow(provider: provider)
                    }
                } header: {
                    Text("Chat & coding providers")
                } footer: {
                    Text("Tap Edit to paste a key. The arrow button opens that provider’s API key page in Safari.")
                }

                Section {
                    // OpenAI is reused for neural TTS — call that out so users know one key covers both.
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "waveform")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OpenAI TTS")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text(state.apiKey(for: .openai).isEmpty
                                 ? "Uses your OpenAI chat key above (not set yet)."
                                 : "Uses your OpenAI chat key above for neural spoken replies.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if let url = ProviderAPIKeyLinks.url(for: .openai) {
                            GetAPIKeyButton(url: url)
                        }
                    }

                    VoiceProviderKeyRow(
                        title: "ElevenLabs",
                        voiceKeyID: VoiceSettingsStore.elevenLabsVoiceKeyID,
                        placeholder: "xi-…",
                        subtitle: "Natural neural voices. Free tier ≈ 10k characters/month."
                    )
                } header: {
                    Text("Voice models")
                } footer: {
                    Text("Spoken replies in voice chat. OpenAI reuses the chat key; ElevenLabs is optional (free plan ≈ 10 minutes of audio/month). Without either key, the app uses built-in free neural voices (Microsoft Edge) — still much better than Apple system TTS.")
                }

                Section {
                    Button {
                        showAddCustom = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add custom provider")
                        }
                    }
                    if !state.customProviders.isEmpty {
                        ForEach(state.customProviders) { provider in
                            CustomProviderRow(provider: provider)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                state.deleteCustomProvider(state.customProviders[index])
                            }
                        }
                    }
                } header: {
                    Text("Custom providers")
                } footer: {
                    Text("Add Ollama, LiteLLM, OpenRouter proxies, or any OpenAI-compatible / Anthropic-compatible host. Pick the endpoint type, set the base URL (include /v1), and store this provider’s own API key — do not put it under OpenAI.")
                }

                Section {
                    Button("Refresh models") {
                        Task { await state.refreshModels() }
                    }
                }

                Section {
                    Text("Keys are stored in the iOS Keychain.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Provider API keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddCustom) {
                AddCustomProviderView()
            }
        }
    }
}

/// Sheet for adding an OpenAI- or Anthropic-style custom provider.
private struct AddCustomProviderView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var style: CustomProviderStyle = .openAI
    @State private var supportsVision: Bool = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    TextField("My proxy / Ollama", text: $label)
                        .textInputAutocapitalization(.words)
                }
                Section {
                    Picker("Endpoint type", selection: $style) {
                        ForEach(CustomProviderStyle.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    TextField(style == .openAI
                             ? "http://localhost:11434/v1"
                             : "https://api.example.com/v1",
                             text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Endpoint")
                } footer: {
                    Text(style.detail + "\nBase URL must include the version segment (e.g. …/v1), not the full /chat/completions or /messages path.")
                }
                Section {
                    Toggle("Supports vision", isOn: $supportsVision)
                } footer: {
                    Text("When on, models from this provider appear in Vision mode and show a Vision badge (except embeddings / TTS-style model ids). Use for Ollama VLMs, multimodal proxies, and similar.")
                }
                Section {
                    SecureField(style == .anthropic ? "sk-ant-…" : "sk-… / ollama (optional)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("API key for this provider")
                } footer: {
                    Text("Stored under this custom provider only — not the built-in OpenAI field.")
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Add custom provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(label.isEmpty || baseURL.isEmpty)
                }
            }
        }
    }

    private func save() {
        let provider = state.addCustomProvider(
            label: label,
            baseURL: baseURL,
            apiKey: apiKey,
            style: style,
            supportsVision: supportsVision
        )
        if provider == nil {
            error = "Couldn't save. Check the base URL and try a unique label."
            return
        }
        Task { await state.refreshModels() }
        dismiss()
    }
}

private struct CustomProviderRow: View {
    @EnvironmentObject var state: AppState
    let provider: CustomProvider
    @State private var showEdit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showEdit = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(provider.label)
                                .foregroundStyle(Theme.textPrimary)
                            if provider.supportsVision {
                                Text("Vision")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.yellow)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.yellow.opacity(0.18), in: Capsule())
                            }
                        }
                        Text(provider.style.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Text(provider.baseURL)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(state.apiKey(for: provider.providerID).isEmpty ? "No key" : "••••••")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .sheet(isPresented: $showEdit) {
                EditCustomProviderView(provider: provider)
            }

            CustomProviderModelsSection(provider: provider)
        }
    }
}

/// Inline list of the models the app already discovered for this custom
/// provider, plus a Refresh button. Empty when the catalog hasn't run yet.
private struct CustomProviderModelsSection: View {
    @EnvironmentObject var state: AppState
    let provider: CustomProvider

    private var models: [AIModel] {
        state.providerResults
            .first(where: { $0.provider == provider.providerID })
            .map { state.visibleModels(in: $0) }
            ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Models")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    Task { await state.refreshModels() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if models.isEmpty {
                Text("No models loaded yet. Tap refresh.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(models) { model in
                    HStack(spacing: 6) {
                        Text("• " + state.displayName(for: model))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        if state.modelSupportsVision(model) {
                            Text("Vision")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.yellow)
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
        .padding(.leading, 16)
        .padding(.bottom, 12)
    }
}

/// Edit base URL, endpoint type, and API key for an existing custom provider.
private struct EditCustomProviderView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let provider: CustomProvider

    @State private var label: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var style: CustomProviderStyle = .openAI
    @State private var supportsVision: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    TextField("Label", text: $label)
                }
                Section {
                    Picker("Endpoint type", selection: $style) {
                        ForEach(CustomProviderStyle.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Endpoint")
                } footer: {
                    Text(style.detail)
                }
                Section {
                    Toggle("Supports vision", isOn: $supportsVision)
                } footer: {
                    Text("When on, models from this provider appear in Vision mode and show a Vision badge (except embeddings / TTS-style model ids).")
                }
                Section("API key") {
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Edit provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        state.updateCustomProvider(
                            provider,
                            label: label,
                            baseURL: baseURL,
                            style: style,
                            apiKey: apiKey,
                            supportsVision: supportsVision
                        )
                        Task { await state.refreshModels() }
                        dismiss()
                    }
                    .disabled(label.isEmpty || baseURL.isEmpty)
                }
            }
            .onAppear {
                label = provider.label
                baseURL = provider.baseURL
                style = provider.style
                supportsVision = provider.supportsVision
                apiKey = state.apiKey(for: provider.providerID)
            }
        }
    }
}

private struct ProviderKeyRow: View {
    @EnvironmentObject var state: AppState
    let provider: ProviderID
    @State private var key = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(provider.displayName)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if editing {
                    SecureField("API key", text: $key)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                } else {
                    Text(state.apiKey(for: provider).isEmpty ? "Not set" : "••••••")
                        .foregroundStyle(Theme.textSecondary)
                    Button("Edit") {
                        key = state.apiKey(for: provider)
                        editing = true
                    }
                }
                if let url = ProviderAPIKeyLinks.url(for: provider) {
                    GetAPIKeyButton(url: url)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func save() {
        state.setAPIKey(key, for: provider)
        editing = false
    }
}

/// Key row for voice-only providers (ElevenLabs, etc.) stored under `SecretKey.voiceAPIKey`.
private struct VoiceProviderKeyRow: View {
    @EnvironmentObject var state: AppState
    let title: String
    let voiceKeyID: String
    var placeholder: String = "API key"
    var subtitle: String? = nil

    @State private var key = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if editing {
                    SecureField(placeholder, text: $key)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                } else {
                    Text(state.voiceAPIKey(for: voiceKeyID).isEmpty ? "Not set" : "••••••")
                        .foregroundStyle(Theme.textSecondary)
                    Button("Edit") {
                        key = state.voiceAPIKey(for: voiceKeyID)
                        editing = true
                    }
                }
                if let url = ProviderAPIKeyLinks.voiceProviderURL(id: voiceKeyID) {
                    GetAPIKeyButton(url: url)
                }
            }
        }
    }

    private func save() {
        state.setVoiceAPIKey(key, for: voiceKeyID)
        editing = false
    }
}

/// Opens the provider’s API key management page in the browser.
private struct GetAPIKeyButton: View {
    @Environment(\.openURL) private var openURL
    let url: URL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Get API key")
        .accessibilityHint("Opens the provider’s API key page in Safari")
    }
}

// MARK: - About sheet

private struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RoamSocket")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Version \(appVersion)")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("An open-source iOS client for any AI provider, paired with a desktop coding server.")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                if let url = URL(string: "https://github.com/kind365/code-mobile-ai") {
                                    openURL(url)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.forward.app")
                                    Text("Project repository")
                                }
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.selection)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    AppSettingsView()
        .environmentObject(AppState(secrets: KeychainSecretStore()))
}

// MARK: - Desktop status dot

/// Coloured dot for the Desktop server row. Callers resolve the
/// colour from the current reachability + reconnecting state so the
/// view doesn't have to read from `AppState` (this file doesn't own
/// the AppState instance).
private struct DesktopStatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 3)
            )
    }
}

// MARK: - Quick access card

/// One row of the `Quick access` section. Three things on each card:
///   - an SF Symbol for the area,
///   - a status pill (e.g. "Linked", "Setup", "Desktop"),
///   - a chevron that hints "tap to open".
private struct QuickAccessCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let statusLabel: String
    /// When true, the status pill uses the accent colour. When false,
    /// the pill is neutral and the user knows the area needs setup.
    let isReady: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isReady ? Theme.accent : Theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(
                        (isReady ? Theme.accent : Theme.textTertiary).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10),
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                StatusPill(label: statusLabel, isReady: isReady)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StatusPill: View {
    let label: String
    let isReady: Bool
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isReady ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (isReady ? Theme.accent : Theme.textTertiary).opacity(0.12),
                in: Capsule(),
            )
    }
}

