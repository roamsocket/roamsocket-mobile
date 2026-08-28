import SwiftUI
import AnyProvCore
import UIKit

/// Sandboxes (E2B) — see the runs the desktop server kicked off after each
/// `git_publish`, set a per-connection user-override API key, and (when the
/// server has admin keys configured) re-run a session. The view opens a
/// dedicated WebSocket so it can keep streaming logs after the chat or
/// code session has been dismissed.
struct SandboxesView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var store = SandboxesStore()

    @State private var showKeySheet = false
    @State private var keyDraft = ""
    @State private var showError: String?
    @State private var filter: SandboxesView.RunFilter = .all

    enum RunFilter: String, CaseIterable, Hashable {
        case all = "All"
        case running = "Running"
        case completed = "Completed"
        case failed = "Failed"

        /// Match helper. `failed` covers both `failed` and `killed` so
        /// users can quickly triage runs that didn't finish cleanly.
        func matches(_ run: E2bRunPayload) -> Bool {
            switch self {
            case .all: return true
            case .running: return run.status == "running" || run.status == "queued"
            case .completed: return run.status == "completed"
            case .failed: return run.status == "failed" || run.status == "killed"
            }
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
                        keyDraft = ""
                        showKeySheet = true
                    } label: {
                        Image(systemName: store.hasUserKey ? "key.fill" : "key")
                    }
                }
            }
            .task {
                await store.start(
                    endpoint: state.serverEndpoint,
                    token: state.serverToken,
                )
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

    private var filteredRuns: [E2bRunPayload] {
        store.runs.filter(filter.matches)
    }

    @ViewBuilder
    private var content: some View {
        if !store.isReady {
            VStack(spacing: 12) {
                ProgressView().tint(Theme.accent)
                Text("Connecting to desktop…")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.runs.isEmpty {
            EmptyState()
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    KeyBanner(
                        hasUserKey: store.hasUserKey,
                        lastStatus: store.lastStatusLabel,
                        onTapKey: { showKeySheet = true },
                    )
                    filterBar
                    if filteredRuns.isEmpty {
                        EmptyFilter(filter: filter) { self.filter = .all }
                    } else {
                        ForEach(filteredRuns) { run in
                            RunCard(
                                run: run,
                                onAbort: { Task { await store.abort(runId: run.id) } },
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .refreshable {
                await store.refresh()
            }
        }
    }

    /// Segmented filter. Only renders once we have runs (the empty state
    /// doesn't need it) so it doesn't waste vertical space on first launch.
    private var filterBar: some View {
        Picker("Filter", selection: $filter) {
            ForEach(RunFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Empty states

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("No sandbox runs yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("After you push a branch, the desktop server can spin up an E2B sandbox to run it. Configure the admin key on the desktop, or set your own below.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyFilter: View {
    let filter: SandboxesView.RunFilter
    var onShowAll: () -> Void
    var body: some View {
        VStack(spacing: 6) {
            Text("No \(filter.rawValue.lowercased()) runs")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Button("Show all runs", action: onShowAll)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
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

// MARK: - Run card

private struct RunCard: View {
    let run: E2bRunPayload
    let onAbort: () -> Void

    @State private var expanded = false
    @State private var showCopied = false
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
                    StatusDot(status: run.status)
                    Text(run.repoFullName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if run.status == "running" {
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
                    Text(run.branch)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusTint)
                }
                if let sandboxUrl = run.sandboxUrl, !sandboxUrl.isEmpty {
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
            if run.command.isEmpty && run.outputTail.isEmpty && run.error == nil {
                Text("No output yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                if !run.command.isEmpty {
                    commandRow
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(run.outputTail.joined(separator: "\n").isEmpty
                         ? " "
                         : run.outputTail.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                if let err = run.error, !err.isEmpty {
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
                copyBar
            }
        }
    }

    /// `$ <command>` line + a per-line copy button. The button only copies
    /// the command itself, not the full output.
    private var commandRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("$ \(run.command)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = run.command
                flashCopied()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy command")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// Bottom row with a "Copy all output" button + a transient confirmation
    /// label. The label auto-clears after a beat so it doesn't linger.
    private var copyBar: some View {
        HStack {
            if showCopied {
                Text("Copied")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.selection)
                    .transition(.opacity)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = run.outputTail.joined(separator: "\n")
                flashCopied()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Copy output")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy run output")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func flashCopied() {
        withAnimation(.easeOut(duration: 0.15)) { showCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) { showCopied = false }
            }
        }
    }

    private var statusLabel: String {
        switch run.status {
        case "queued": return "QUEUED"
        case "running": return "RUNNING"
        case "completed": return run.exitCode.map { "DONE · \($0)" } ?? "DONE"
        case "failed": return run.exitCode.map { "FAILED · \($0)" } ?? "FAILED"
        case "killed": return "KILLED"
        default: return run.status.uppercased()
        }
    }

    private var statusTint: Color {
        switch run.status {
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

// MARK: - E2B key sheet

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
                    Text("Your E2B key")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Paste an e2b.dev API key to override the admin-managed key on the desktop. The override is held in memory only and is cleared when you disconnect.")
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
