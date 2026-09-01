import SwiftUI
import AnyProvCore
import UIKit

/// One row in the Sandboxes list. Always phone-originated now —
/// the desktop no longer brokers E2B runs, so the view doesn't
/// need a `source` field or a unified-runs computed property.
fileprivate struct RunRow: Identifiable, Hashable {
    let id: String
    let repoFullName: String
    let branch: String
    let status: String
    let exitCode: Int?
    let sandboxUrl: String?
    let command: String
    let outputTail: [String]
    let error: String?
    let startedAt: Double?
    let steps: [E2bPhoneRunStep]
}

/// Sandboxes (E2B) — phone-originated runs only. The desktop
/// server is no longer in the loop: the iOS app talks to e2b.dev
/// directly with the user's own API key. The view shows the
/// in-flight + historical runs and exposes a "Start a run" sheet.
struct SandboxesView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var store = SandboxesStore()

    @State private var showError: String?
    @State private var showStartSheet = false

    private var rows: [RunRow] {
        store.phoneRuns.map { run in
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
                    .disabled(!state.e2bKeyStore.hasKey)
                }
            }
            .onDisappear {
                store.stop()
            }
            .sheet(isPresented: $showStartSheet) {
                StartRunSheet(
                    onStart: { req in startRun(req) },
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
        if rows.isEmpty {
            EmptyState(
                hasPhoneKey: state.e2bKeyStore.hasKey,
                onStart: { showStartSheet = true },
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(rows) { row in
                        RunRowView(row: row, onStop: {
                            store.cancelPhoneRun(runId: row.id)
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
    let onStop: () -> Void

    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                if !row.steps.isEmpty {
                    stepPills
                }
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
                    Spacer()
                    if row.status == "running" {
                        Button("Stop", action: onStop)
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

    /// Compact "Clone → Install → Test" pipeline pills. Mirrors the
    /// current `E2bPhoneRunStep` state for each step.
    private var stepPills: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.separator)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(row.steps) { step in
                        StepPill(step: step)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var outputBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !row.steps.isEmpty {
                Divider().overlay(Theme.separator)
            }
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
                if let err = row.error, !err.isEmpty, row.status != "killed" {
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
        case "killed": return "STOPPED"
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

/// Compact "Clone" / "Install" / "Test" pill for the pipeline view.
/// Reflects the per-step status from the run's `steps` array.
private struct StepPill: View {
    let step: E2bPhoneRunStep

    var body: some View {
        HStack(spacing: 4) {
            statusIcon
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
            Text(step.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(step.status == "pending" ? Theme.textTertiary : Theme.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case "running": ProgressView().controlSize(.mini)
        case "completed": Image(systemName: "checkmark")
        case "failed": Image(systemName: "xmark")
        case "skipped": Image(systemName: "minus")
        default: Image(systemName: "circle")
        }
    }

    private var tint: Color {
        switch step.status {
        case "running": return Theme.accent
        case "completed": return Theme.selection
        case "failed": return .red
        case "skipped": return Theme.textTertiary
        default: return Theme.textTertiary
        }
    }

    private var background: Color {
        switch step.status {
        case "running": return Theme.accent.opacity(0.15)
        case "completed": return Theme.selection.opacity(0.15)
        case "failed": return Color.red.opacity(0.15)
        case "skipped": return Theme.surfaceElevated
        default: return Theme.surfaceElevated
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

// MARK: - Empty state

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
            Text(hasPhoneKey
                 ? "Tap play to spin up a fresh e2b sandbox and run a command on your repo."
                 : "Add your e2b.dev key in Settings → Sandboxes (E2B) to start runs from this device.")
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Start a run sheet (phone-originated runs)

/// "Start a run" sheet. The user picks a repo (GitHub list or
/// pasted URL), a branch, and a preset. The phone drives the
/// run directly via e2b.dev — no desktop required.
private struct StartRunSheet: View {
    let onStart: (E2bPhoneRunRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var source: E2bPhoneRepoSource = .github
    @State private var pickedRepo: GitHubRepo?
    @State private var url: String = ""
    @State private var branch: String = "main"
    @State private var command: String = "ls -la"
    @State private var showRepoPicker = false
    @State private var hasGitHubToken = false
    /// When the user picks a preset, the `command` field is
    /// populated with the manifest's command and locked. Free-form
    /// command editing requires the "Custom" preset.
    @State private var preset: RunPreset = .test
    @State private var manifest: ProjectManifest = .unknown

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
                        // Preset chips. The chips that don't apply to
                        // the detected manifest are greyed out so the
                        // user can't pick something that will fail
                        // silently. "Custom" is always available.
                        PresetChipsRow(preset: $preset, manifest: manifest)
                    } header: {
                        Text("Run")
                    } footer: {
                        Text(presetFooter)
                            .font(.system(size: 11))
                    }

                    Section {
                        TextField("command", text: $command, axis: .vertical)
                            .lineLimit(2...5)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 14, design: .monospaced))
                            .disabled(preset != .custom)
                    } header: {
                        Text("Command")
                    } footer: {
                        Text(preset == .custom
                             ? "Runs inside the cloned repo at /code."
                             : "Auto-filled from the preset. Switch to Custom to edit.")
                            .font(.system(size: 11))
                    }

                    Section {
                        Label {
                            Text("Runs from this device using your e2b.dev key.")
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
                // Pre-populate the command from the manifest's test
                // preset so the sheet lands in a useful state.
                applyPreset(.test)
            }
            .onChange(of: pickedRepo) { _, _ in
                // Project manifest detection would happen here once
                // the user picks a repo — the iOS app would need a
                // small GitHub contents API call. For the MVP, we
                // leave the manifest as .unknown; the user can still
                // pick any preset and the shim will run the chosen
                // command. A future commit adds manifest detection.
            }
        }
    }

    private var presetFooter: String {
        switch preset {
        case .test: return "Runs the project test command (e.g. `npm test`, `pytest -q`)."
        case .build: return "Runs the project build command (e.g. `npm run build`, `cargo build`)."
        case .lint: return "Runs the project lint command (e.g. `npm run lint`, `ruff check`)."
        case .install: return "Just installs dependencies, then exits."
        case .custom: return "Type any shell command. Use shell syntax — e.g. `pytest -q -k auth`."
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
        // The install step is only added when the user picked the
        // "install" preset — otherwise the shim emits
        // STEP:install:skipped and falls straight through.
        let installCommand: String? = {
            switch preset {
            case .install: return manifest.installCommand ?? "true"
            default: return manifest.installCommand
            }
        }()
        onStart(E2bPhoneRunRequest(
            repo: repo,
            branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            installCommand: installCommand,
            githubToken: state.githubToken,
            preset: preset.rawValue,
        ))
    }

    private func applyPreset(_ p: RunPreset) {
        preset = p
        switch p {
        case .test:
            command = manifest.testCommand ?? "echo \"(no test command for this project — switch to Custom)\""
        case .build:
            command = manifest.buildCommand ?? manifest.testCommand ?? "echo \"(no build command — switch to Custom)\""
        case .lint:
            command = manifest.lintCommand ?? "echo \"(no lint command — switch to Custom)\""
        case .install:
            command = manifest.installCommand ?? "true"
        case .custom:
            // Leave the field alone — the user types into it.
            break
        }
    }
}

/// User-facing run preset. Drives the chip row + the `E2bPhoneRunRequest.preset`
/// string so the Sandboxes view can label the pill ("Test" / "Build" / etc.).
private enum RunPreset: String, CaseIterable, Hashable {
    case test, build, lint, install, custom
    var displayName: String {
        switch self {
        case .test: return "Test"
        case .build: return "Build"
        case .lint: return "Lint"
        case .install: return "Install"
        case .custom: return "Custom"
        }
    }
    /// Which presets apply to a given manifest. `custom` is always
    /// available. Unknown manifests offer all presets via
    /// "echo" fallbacks (handled in `applyPreset`) so the user can
    /// still hit Start.
    static func available(for manifest: ProjectManifest) -> Set<RunPreset> {
        var s: Set<RunPreset> = [.custom]
        if manifest.testCommand != nil { s.insert(.test) }
        if manifest.buildCommand != nil { s.insert(.build) }
        if manifest.lintCommand != nil { s.insert(.lint) }
        if manifest.installCommand != nil { s.insert(.install) }
        return s
    }
}

private struct PresetChipsRow: View {
    @Binding var preset: RunPreset
    let manifest: ProjectManifest

    var body: some View {
        let available = RunPreset.available(for: manifest)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RunPreset.allCases, id: \.self) { p in
                    let isAvailable = available.contains(p)
                    Button {
                        preset = p
                    } label: {
                        Text(p.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(foreground(for: p, isAvailable: isAvailable))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(background(for: p, isAvailable: isAvailable), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAvailable)
                }
            }
        }
    }

    private func foreground(for p: RunPreset, isAvailable: Bool) -> Color {
        if !isAvailable { return Theme.textTertiary }
        return p == preset ? Theme.background : Theme.textPrimary
    }

    private func background(for p: RunPreset, isAvailable: Bool) -> Color {
        if !isAvailable { return Theme.surfaceElevated }
        return p == preset ? Theme.accent : Theme.surfaceElevated
    }
}
