import SwiftUI
import AnyProvCore
import UIKit

/// Unified run row — desktop-originated runs get `source = .desktop`
/// and phone-originated runs get `source = .phone`. Keeps the view
/// logic from caring which kind each card came from.
fileprivate struct RunRow: Identifiable, Hashable {
    enum Source: String, Hashable { case desktop, phone }
    let id: String
    let source: Source
    let repoFullName: String
    let branch: String
    let status: String
    let exitCode: Int?
    let sandboxUrl: String?
    let command: String
    let outputTail: [String]
    let error: String?
    let startedAt: Double?
}

/// Sandboxes (E2B) — see the runs the desktop server kicked off after each
/// `git_publish`, set a per-connection user-override API key, **or** start
/// a run directly from the phone (no desktop required) by talking to
/// e2b.dev with the user's own API key.
struct SandboxesView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var store = SandboxesStore()

    @State private var showKeySheet = false
    @State private var keyDraft = ""
    @State private var showError: String?
    @State private var showStartSheet = false

    private var unifiedRuns: [RunRow] {
        let desktop = store.runs.map { run in
            RunRow(
                id: run.id,
                source: .desktop,
                repoFullName: run.repoFullName,
                branch: run.branch,
                status: run.status,
                exitCode: run.exitCode,
                sandboxUrl: run.sandboxUrl,
                command: run.command,
                outputTail: run.outputTail,
                error: run.error,
                startedAt: run.startedAt,
            )
        }
        let phone = store.phoneRuns.map { run in
            RunRow(
                id: run.id,
                source: .phone,
                repoFullName: run.repoFullName,
                branch: run.branch,
                status: run.status,
                exitCode: run.exitCode,
                sandboxUrl: run.sandboxUrl,
                command: run.command,
                outputTail: run.outputTail,
                error: run.error,
                startedAt: run.startedAt,
            )
        }
        return (desktop + phone).sorted { (a, b) in
            (a.startedAt ?? 0) > (b.startedAt ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Sandboxes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showStartSheet = true
                    } label: {
                        Image(systemName: "play.fill")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        keyDraft = ""
                        showKeySheet = true
                    } label: {
                        Image(systemName: store.hasUserKey ? "key.fill" : "key")
                    }
                }
            }
            .task {
                if state.serverEndpoint != nil && state.serverToken != nil {
                    await store.start(
                        endpoint: state.serverEndpoint,
                        token: state.serverToken,
                    )
                }
            }
            .onDisappear {
                store.stop()
            }
            .sheet(isPresented: $showKeySheet) {
                E2bKeySheet(
                    hasUserKey: store.hasUserKey,
                    draft: $keyDraft,
                    onSave: { newKey in
                        Task { await store.setKey(newKey) }
                        showKeySheet = false
                    },
                    onClear: {
                        Task { await store.setKey("") }
                        showKeySheet = false
                    },
                )
            }
            .sheet(isPresented: $showStartSheet) {
                StartRunSheet(
                    desktopPaired: state.serverEndpoint != nil && state.serverToken != nil,
                    desktopKeyHint: store.hasUserKey,
                    onStart: { req in
                        startRun(req)
                    },
                )
                .presentationDetents([.large])
            }
            .alert("Sandbox error", isPresented: Binding(
                get: { showError != nil },
                set: { if !$0 { showError = nil } }
            )) {
                Button("OK", role: .cancel) { showError = nil }
            } message: {
                Text(showError ?? "")
            }
        }
        .onReceive(store.errors) { err in
            if let err { showError = err }
        }
    }

    private func startRun(_ req: E2bPhoneRunRequest) {
        // The phone always drives "Start a run" directly via e2b.dev —
        // even when a desktop is paired. The desktop's e2b_start path
        // requires an active session, which a user coming from the
        // Sandboxes sheet doesn't necessarily have. Direct keeps the
        // UX consistent: one tap on "Start" → run starts.
        guard let apiKey = state.e2bKeyStore.get(), !apiKey.isEmpty else {
            showError = "Add your e2b.dev API key in Settings → Sandboxes (E2B) first."
            return
        }
        store.startPhoneRun(
            apiKey: apiKey,
            githubToken: state.githubToken,
            request: req,
        )
        showStartSheet = false
    }

    @ViewBuilder
    private var content: some View {
        if !store.isReady && store.runs.isEmpty && store.phoneRuns.isEmpty {
            VStack(spacing: 12) {
                if state.serverEndpoint != nil && state.serverToken != nil {
                    ProgressView().tint(Theme.accent)
                    Text("Connecting to desktop…")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    NoDesktopEmptyState(
                        hasKey: state.e2bKeyStore.hasKey,
                        onStart: { showStartSheet = true },
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if unifiedRuns.isEmpty {
            EmptyState(
                hasPhoneKey: state.e2bKeyStore.hasKey,
                onStart: { showStartSheet = true },
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if !store.isReady {
                        KeyBanner(
                            hasUserKey: store.hasUserKey,
                            lastStatus: store.lastStatusLabel,
                            onTapKey: { showKeySheet = true },
                        )
                    }
                    ForEach(unifiedRuns) { row in
                        RunRowView(row: row, onAbort: {
                            Task { await store.abort(runId: row.id) }
                        })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - Run row

private struct RunRowView: View {
    let row: RunRow
    let onAbort: () -> Void

    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                outputBody
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.separator.opacity(0.6), lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(status: row.status)
                    Text(row.repoFullName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if row.source == .phone {
                        Text("PHONE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    }
                    Spacer()
                    if row.status == "running" {
                        Button("Stop", action: onAbort)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red)
                            .buttonStyle(.plain)
                    } else {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                HStack(spacing: 8) {
                    Text(row.branch)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusTint)
                }
                if let sandboxUrl = row.sandboxUrl, !sandboxUrl.isEmpty {
                    Button {
                        if let url = URL(string: sandboxUrl) { openURL(url) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 10, weight: .semibold))
                            Text(sandboxUrl)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .buttonStyle(.plain)
    }

    private var outputBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Theme.separator)
            if row.command.isEmpty && row.outputTail.isEmpty && row.error == nil {
                Text("No output yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                if !row.command.isEmpty {
                    Text("$ \(row.command)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(row.outputTail.joined(separator: "\n").isEmpty
                         ? " "
                         : row.outputTail.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                if let err = row.error, !err.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private var statusLabel: String {
        switch row.status {
        case "queued": return "QUEUED"
        case "running": return "RUNNING"
        case "completed": return row.exitCode.map { "DONE · \($0)" } ?? "DONE"
        case "failed": return row.exitCode.map { "FAILED · \($0)" } ?? "FAILED"
        case "killed": return "KILLED"
        default: return row.status.uppercased()
        }
    }

    private var statusTint: Color {
        switch row.status {
        case "completed": return Theme.selection
        case "failed", "killed": return .red
        case "running": return Theme.accent
        default: return Theme.textSecondary
        }
    }
}

private struct StatusDot: View {
    let status: String
    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 8, height: 8)
    }
    private var tint: Color {
        switch status {
        case "completed": return Theme.selection
        case "failed", "killed": return .red
        case "running": return Theme.accent
        default: return Theme.textTertiary
        }
    }
}

// MARK: - Empty states

private struct EmptyState: View {
    let hasPhoneKey: Bool
    let onStart: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("No sandbox runs yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Start a run from your phone to spin up a clean E2B sandbox — no PC required.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
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
            if !hasPhoneKey {
                Text("Add your e2b.dev key in Settings → Sandboxes (E2B) to start runs without a paired desktop.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NoDesktopEmptyState: View {
    let hasKey: Bool
    let onStart: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("No desktop paired")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("You can still run sandboxes from this device by setting your e2b.dev API key in Settings, then tapping Start a run.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if hasKey {
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Key banner

private struct KeyBanner: View {
    let hasUserKey: Bool
    let lastStatus: String?
    var onTapKey: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hasUserKey ? "key.fill" : "key.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hasUserKey ? Theme.accent : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(hasUserKey ? "Using your own E2B key" : "Using the admin-managed E2B key")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let lastStatus {
                    Text(lastStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Button(hasUserKey ? "Change" : "Set your own", action: onTapKey)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.separator.opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - Start a run sheet (phone-originated runs)

/// "Start a run" sheet. The user picks a repo (GitHub list or pasted
/// URL), a branch, and a command. The phone drives the run directly
/// via e2b.dev — no desktop required.
private struct StartRunSheet: View {
    let desktopPaired: Bool
    let desktopKeyHint: Bool
    let onStart: (E2bPhoneRunRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var source: E2bPhoneRepoSource = .github
    @State private var pickedRepo: GitHubRepo?
    @State private var url: String = ""
    @State private var branch: String = "main"
    @State private var command: String = "ls -la"
    @State private var showRepoPicker = false
    @State private var hasGitHubToken = false

    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                Form {
                    Section {
                        Picker("Source", selection: $source) {
                            Text("My GitHub repos").tag(E2bPhoneRepoSource.github)
                            Text("Paste a URL").tag(E2bPhoneRepoSource.url)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Repo")
                    } footer: {
                        if source == .github {
                            if !hasGitHubToken {
                                Text("Link a GitHub PAT in Settings to pick from your repos.")
                                    .font(.system(size: 11))
                            } else {
                                Text("Picks from your GitHub repos via the linked PAT.")
                                    .font(.system(size: 11))
                            }
                        } else {
                            Text("Any public Git URL. For private repos, link a GitHub PAT first.")
                                .font(.system(size: 11))
                        }
                    }

                    if source == .github {
                        Section {
                            Button {
                                showRepoPicker = true
                            } label: {
                                HStack {
                                    Text(pickedRepo?.fullName ?? "Select repo")
                                        .foregroundStyle(pickedRepo == nil ? Theme.textSecondary : Theme.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .foregroundStyle(Theme.textTertiary)
                                        .font(.system(size: 12, weight: .semibold))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Section {
                            TextField("https://github.com/owner/repo.git", text: $url)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 14, design: .monospaced))
                        } header: {
                            Text("Git URL")
                        }
                    }

                    Section {
                        TextField("main", text: $branch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 14, design: .monospaced))
                    } header: {
                        Text("Branch")
                    } footer: {
                        Text("Default: main. Use the branch you want to test.")
                            .font(.system(size: 11))
                    }

                    Section {
                        TextField("npm test", text: $command, axis: .vertical)
                            .lineLimit(2...5)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 14, design: .monospaced))
                    } header: {
                        Text("Command")
                    } footer: {
                        Text("Runs inside the cloned repo at /code. Use shell syntax — e.g. `npm test`, `pytest -q`, `cargo test --quiet`.")
                            .font(.system(size: 11))
                    }

                    Section {
                        Label {
                            Text(desktopPaired
                                 ? "Will run from this device (desktop auto-runs stay as-is)."
                                 : "Will run from this device using your e2b.dev key.")
                        } icon: {
                            Image(systemName: "iphone")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Start a run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .disabled(!isValid)
                }
            }
            .sheet(isPresented: $showRepoPicker) {
                RepositoryPickerSheet()
                    .environmentObject(state)
                    .onDisappear {
                        // After the picker dismisses, try to grab the
                        // most recently selected repo from the sheet's
                        // published state via the global `state`.
                        if let recent = state.selectedRepo {
                            pickedRepo = recent
                            if branch.isEmpty || branch == "main" {
                                branch = recent.defaultBranch
                            }
                        }
                    }
            }
            .onAppear {
                hasGitHubToken = !(state.githubToken ?? "").isEmpty
            }
        }
    }

    private var isValid: Bool {
        switch source {
        case .github: return pickedRepo != nil && !branch.isEmpty && !command.isEmpty
        case .url: return !url.isEmpty && !branch.isEmpty && !command.isEmpty
        }
    }

    private func start() {
        let repo: E2bPhoneRepoSelection
        switch source {
        case .github:
            guard let pickedRepo else { return }
            repo = .github(fullName: pickedRepo.fullName)
        case .url:
            repo = .url(url.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        onStart(E2bPhoneRunRequest(
            repo: repo,
            branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            githubToken: state.githubToken,
        ))
    }
}

// MARK: - E2B key sheet (in-Sandboxes toolbar)

private struct E2bKeySheet: View {
    let hasUserKey: Bool
    @Binding var draft: String
    var onSave: (String) -> Void
    var onClear: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Desktop E2B key")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Override the admin-managed E2B key on the desktop for this connection. Held in memory only.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    SecureField("e2b_…", text: $draft)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(12)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        if hasUserKey {
                            Button(role: .destructive) {
                                onClear()
                            } label: {
                                Text("Clear override")
                            }
                        }
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(Theme.textSecondary)
                        Button("Save") { onSave(draft) }
                            .foregroundStyle(Theme.accent)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("E2B key")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
