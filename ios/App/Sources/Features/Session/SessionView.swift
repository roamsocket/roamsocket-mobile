import SwiftUI
import MobileAICore

/// The coding-session transcript: streamed assistant text, tool cards, diffs,
/// permission prompts, and a Create-PR action.
struct SessionView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openURL) private var openURL
    @StateObject private var model: SessionViewModel
    @State private var followUp = ""
    @State private var showPRSheet = false
    @State private var prTitle = ""
    @State private var showTools = false
    @State private var showModelPicker = false
    @State private var showEnvironmentPicker = false
    @State private var showPermissionSheet = false
    @State private var showProviderSettings = false
    @State private var detailTool: SessionViewModel.Item?

    private let config: SessionConfig

    init(config: SessionConfig) {
        self.config = config
        _model = StateObject(wrappedValue: SessionViewModel(config: config, client: ServerClient()))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                transcript
                if let permission = model.pendingPermission {
                    permissionBar(permission)
                }
                inputArea
            }
        }
        .navigationTitle(config.repo.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showTools = true } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if model.hasDiffs {
                    Button {
                        prTitle = config.firstMessage
                        showPRSheet = true
                    } label: {
                        let stats = model.totalDiffStats
                        Text("+\(stats.added) −\(stats.removed)")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.selection)
                    }
                }
            }
        }
        .sheet(isPresented: $showTools) {
            SessionToolsView()
        }
        .sheet(isPresented: $showPRSheet) { prSheet }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet()
        }
        .sheet(isPresented: $showProviderSettings) {
            // Reuse the existing settings screen so the providers UI stays
            // single-sourced — same body as the entry from the home screen.
            // Land directly on the providers section when the user came
            // from the "+ Add a model" pill so they don't have to tap
            // through again.
            ClaudeSettingsView(initialFocus: .providers)
        }
        .sheet(isPresented: $showEnvironmentPicker) {
            EnvironmentPickerSheet()
        }
        .sheet(isPresented: $showPermissionSheet) {
            PermissionModeSheet(selection: permissionBinding)
        }
        .sheet(item: $detailTool) { item in
            if case let .tool(_, tool, summary, ok, output) = item {
                ToolDetailSheet(tool: tool, summary: summary, ok: ok, output: output)
            }
        }
        .onChange(of: model.prURL) { _, url in
            if let url { openURL(url) }
        }
        .onAppear {
            model.state = state
            model.start()
        }
        .onDisappear { model.stop() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.items) { item in
                        row(for: item).id(item.id)
                    }
                    if let error = model.connectionError {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .onChange(of: model.items.count) { _, _ in
                if let last = model.items.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: SessionViewModel.Item) -> some View {
        switch item {
        case let .assistant(_, text):
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .tool(_, tool, summary, ok, output):
            Button {
                detailTool = item
            } label: {
                ToolCard(tool: tool, summary: summary, ok: ok, output: output)
            }
            .buttonStyle(.plain)

        case let .diff(_, path, patch, added, removed):
            DiffCard(path: path, patch: patch, added: added, removed: removed)

        case let .notice(_, text):
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionBar(_ permission: SessionViewModel.PendingPermission) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow \(permission.tool)?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(permission.summary)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Deny") { model.respond(to: permission, allow: false) }
                .buttonStyle(.bordered)
            Button("Allow") { model.respond(to: permission, allow: true) }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Theme.surfaceElevated)
    }

    /// Input area split into two rows: the chat text box on top, then a
    /// second row with the action pills and send button. Matches the
    /// Claude Code iOS reference where the prompt lives above the
    /// controls.
    private var inputArea: some View {
        VStack(spacing: 8) {
            messageBox
            actionRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.background)
    }

    private var messageBox: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                "",
                text: $followUp,
                prompt: Text(model.isRunning ? "Queue for after this turn…" : "Reply…")
                    .foregroundColor(Theme.textTertiary),
                axis: .vertical
            )
            .font(.system(size: 16))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...4)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: model.isRunning) { _, isRunning in
                // When the agent transitions from running → idle, flush
                // any queued follow-up so the user doesn't have to retap.
                if !isRunning { model.sendQueuedMessageIfNeeded() }
            }

            trailingSendButton
        }
    }

    private var trailingSendButton: some View {
        Group {
            if model.isRunning {
                if canSend {
                    Button(action: queueFollowUp) {
                        Image(systemName: "text.append")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { model.interrupt() } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(canSend ? Theme.accent : Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button { /* TODO: attach file / @-mention */ } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Theme.surface, in: Circle())
            }
            .buttonStyle(.plain)

            ModelSelectorPill(
                modelDisplayName: modelPillTitle,
                onPick: { showModelPicker = true },
                onAddModel: { showProviderSettings = true }
            )
            permissionPill
            environmentPill
            Spacer(minLength: 0)

            Button { showTools = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var permissionPill: some View {
        Button {
            if !model.isRunning { showPermissionSheet = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: state.permissionMode.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(state.permissionMode == .acceptEdits ? "Accept edits" : state.permissionMode.displayName)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(model.isRunning ? Theme.textTertiary : Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning)
        .help(model.isRunning ? "Mode is locked while a session is running" : "Change permission mode")
    }

    /// Always show the mode captured in the `SessionConfig` once the session
    /// starts, even if `state.permissionMode` is changed elsewhere. This
    /// keeps the on-screen pill honest about the mode the server received.
    private var permissionBinding: Binding<PermissionMode> {
        Binding(
            get: { model.isRunning ? config.permissionMode : state.permissionMode },
            set: { state.permissionMode = $0 }
        )
    }

    private var environmentPill: some View {
        Button { showEnvironmentPicker = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "cloud")
                    .font(.system(size: 11, weight: .semibold))
                Text(state.selectedEnvironment?.name ?? "Default")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
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

    private var prSheet: some View {
        NavigationStack {
            Form {
                Section("Pull request title") {
                    TextField("Title", text: $prTitle)
                }
            }
            .navigationTitle("Create PR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPRSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        model.createPR(title: prTitle)
                        showPRSheet = false
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var canSend: Bool {
        !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.sendUserMessage(text)
        followUp = ""
    }

    private func queueFollowUp() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.queueMessage(text)
        followUp = ""
    }
}

/// Collapsible tool-call card.
private struct ToolCard: View {
    let tool: String
    let summary: String
    let ok: Bool?
    let output: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(summary)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if output != nil {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded, let output, !output.isEmpty {
                Text(output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusIcon: String {
        switch ok {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "xmark.circle.fill"
        case .none: return "circle.dotted"
        }
    }
    private var statusColor: Color {
        switch ok {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return Theme.textTertiary
        }
    }
}

/// Detail sheet for a single tool invocation. Shows the command/summary
/// at the top and the full output (with syntax-style highlighting for
/// `git`-style output) below.
private struct ToolDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tool: String
    let summary: String
    let ok: Bool?
    let output: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Command")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if let ok {
                            Text(ok ? "OK" : "Failed")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background((ok ? Color.green : Color.red).opacity(0.2), in: Capsule())
                                .foregroundStyle(ok ? .green : .red)
                        }
                    }
                    Text(displayName)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    if let output, !output.isEmpty {
                        Text("Output")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(output.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                    Text(String(line))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(color(for: String(line)))
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(12)
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("No output yet.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle(toolLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var toolLabel: String {
        switch tool {
        case "bash": return "Bash"
        case "read_file", "write_file", "edit_file": return "File"
        default: return tool.capitalized
        }
    }

    private var displayName: String {
        // The summary field carries the human summary; the raw command is
        // in the `input` blob stored on the model. For now we just show
        // the summary.
        summary
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("On branch ") || line.hasPrefix("----") { return Theme.textSecondary }
        if line.contains("nothing to commit") || line.contains("working tree clean") { return Theme.textSecondary }
        return Theme.textPrimary
    }
}

/// A unified-diff card with colorized lines.
private struct DiffCard: View {
    let path: String
    let patch: String
    let added: Int
    let removed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(path)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("+\(added) −\(removed)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.selection)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(String(line))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: String(line)))
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return Theme.selection }
        return Theme.textSecondary
    }
}
