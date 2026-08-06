import SwiftUI
import AnyProvCore
import Combine

/// Legacy combined sheet — prefer separate Shell / Files / Ports sheets.
struct SessionToolsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let sessionId: String
    var initialTab: Tab = .terminal

    @State private var tab: Tab

    enum Tab: String, CaseIterable, Identifiable {
        case terminal = "Shell"
        case files = "Files"
        case ports = "Ports"
        var id: String { rawValue }
    }

    init(sessionId: String, initialTab: Tab = .terminal) {
        self.sessionId = sessionId
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                switch tab {
                case .terminal:
                    TerminalPaneView(sessionId: sessionId)
                case .files:
                    FileExplorerView(sessionId: sessionId)
                case .ports:
                    PortManagerView(sessionId: sessionId)
                }
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents(tab == .terminal ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var title: String {
        switch tab {
        case .terminal: return "Shell"
        case .files: return "Files"
        case .ports: return "Open ports"
        }
    }
}

// MARK: - Shared workspace client helper

/// One short-lived WebSocket for a tools request (file list, ports, tunnels).
/// Separate from the agent session client so tools never drop the agent stream.
@MainActor
enum WorkspaceRPC {
    static func withConnection<T>(
        endpoint: ServerClient.Endpoint,
        token: String,
        timeoutSeconds: TimeInterval = 20,
        send: (ServerClient) async throws -> Void,
        match: @escaping (ServerMessage) -> T?
    ) async throws -> T {
        let client = ServerClient()
        // Connect waits for the socket to open before returning.
        let stream = try await client.connect(endpoint: endpoint, token: token)
        try await send(client)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        for await msg in stream {
            if let value = match(msg) {
                await client.disconnect()
                return value
            }
            if Date() > deadline { break }
        }
        await client.disconnect()
        throw WorkspaceRPCError.timeout
    }
}

enum WorkspaceRPCError: Error, LocalizedError {
    case timeout
    case missingPairing
    var errorDescription: String? {
        switch self {
        case .timeout: return "Desktop did not respond in time."
        case .missingPairing: return "Pair a desktop server first."
        }
    }
}

// MARK: - Terminal (SSH console)

@MainActor
final class TerminalViewModel: ObservableObject {
    @Published var output: String = ""
    @Published var isRunning: Bool = false
    @Published var exitCode: Int?
    @Published var connectionError: String?

    private var terminalId: String?
    private var streamTask: Task<Void, Never>?
    private let client = ServerClient()
    private let sessionId: String
    private var endpoint: ServerClient.Endpoint?
    private var token: String?

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func start(endpoint: ServerClient.Endpoint, token: String) {
        guard streamTask == nil else { return }
        self.endpoint = endpoint
        self.token = token
        isRunning = true
        connectionError = nil
        output = ""
        streamTask = Task { await run() }
    }

    func stop() {
        if let id = terminalId {
            Task { try? await client.send(.terminalKill(terminalId: id)) }
        }
        streamTask?.cancel()
        streamTask = nil
        isRunning = false
        Task { await client.disconnect() }
    }

    func send(_ text: String) {
        guard let id = terminalId else {
            // Echo locally so the user sees input even before ready.
            output += text
            return
        }
        Task { try? await client.send(.terminalInput(terminalId: id, data: text)) }
    }

    private func run() async {
        guard let endpoint, let token else { return }
        do {
            let stream = try await client.connect(endpoint: endpoint, token: token)
            try await client.send(.terminalOpen(terminalId: nil, sessionId: sessionId))
            output += "Connected to session workdir shell.\n"
            for await message in stream {
                if Task.isCancelled { return }
                handle(message)
            }
            if isRunning {
                connectionError = "Shell disconnected."
                isRunning = false
            }
        } catch {
            connectionError = error.localizedDescription
            isRunning = false
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case let .terminalControl(id, event, code):
            if event == "ready" {
                self.terminalId = id
                output += "$ "
            } else if event == "exit" {
                self.exitCode = code
                self.isRunning = false
                output += "\n[process exited \(code)]\n"
            }
        case let .terminalData(_, _, data):
            output += data
        case let .error(_, message):
            connectionError = message
            output += "\nError: \(message)\n"
        default: break
        }
    }
}

struct TerminalPaneView: View {
    let sessionId: String
    @EnvironmentObject var state: AppState
    @StateObject private var model: TerminalViewModel
    @State private var input: String = ""
    @FocusState private var inputFocused: Bool

    init(sessionId: String) {
        self.sessionId = sessionId
        _model = StateObject(wrappedValue: TerminalViewModel(sessionId: sessionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status strip
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isRunning ? Color.green : Color.red.opacity(0.8))
                    .frame(width: 8, height: 8)
                Text(model.isRunning ? "Shell live · \(sessionId)" : "Disconnected")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if model.isRunning {
                    Button("Kill") { model.stop() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red)
                } else if let endpoint = state.serverEndpoint, let token = state.serverToken {
                    Button("Reconnect") {
                        model.start(endpoint: endpoint, token: token)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(displayText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("__bottom__")
                }
                .background(Color.black.opacity(0.35))
                .onChange(of: model.output) { _, _ in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }

            if let err = model.connectionError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            HStack(spacing: 8) {
                Text("$")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                TextField("command", text: $input)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .onSubmit(runCommand)
                Button(action: runCommand) {
                    Image(systemName: "return")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 36, height: 36)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isRunning)
            }
            .padding(10)
            .background(Theme.surfaceElevated)
        }
        .onAppear {
            guard let endpoint = state.serverEndpoint, let token = state.serverToken else {
                model.connectionError = "Pair a desktop server first."
                return
            }
            model.start(endpoint: endpoint, token: token)
            inputFocused = true
        }
        .onDisappear { model.stop() }
    }

    private var displayText: String {
        if model.output.isEmpty {
            return "SSH console — shell opens in the session workdir on your desktop.\nType a command and press Return."
        }
        return model.output
    }

    private func runCommand() {
        let cmd = input
        guard !cmd.isEmpty else {
            model.send("\n")
            return
        }
        // Local echo for responsiveness; server also streams output.
        if !model.output.hasSuffix("\n") && !model.output.isEmpty {
            model.output += "\n"
        }
        model.output += "$ \(cmd)\n"
        model.send(cmd + "\n")
        input = ""
    }
}

// MARK: - File explorer

struct FileExplorerView: View {
    let sessionId: String
    @EnvironmentObject var state: AppState

    @State private var mode: ExplorerMode = .files
    @State private var entries: [ServerMessage.FileEntryPayload] = []
    @State private var changes: [ServerMessage.FileChangePayload] = []
    @State private var fullDiff: String = ""
    @State private var currentPath: String = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedFile: SelectedFile?

    enum ExplorerMode: String, CaseIterable, Identifiable {
        case files = "Browse"
        case diffs = "Diffs"
        var id: String { rawValue }
    }

    struct SelectedFile: Identifiable {
        let id = UUID()
        let path: String
        var preferDiff: Bool = false
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(ExplorerMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if mode == .files {
                breadcrumb
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            Group {
                if mode == .files {
                    filesList
                } else {
                    diffsList
                }
            }
        }
        .overlay {
            if loading { ProgressView().scaleEffect(1.1) }
        }
        .sheet(item: $selectedFile) { file in
            FileViewerSheet(sessionId: sessionId, path: file.path, preferDiff: file.preferDiff)
                .environmentObject(state)
        }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: mode) { _, newMode in
            // Diffs always need the root listing (full patch + change list).
            if newMode == .diffs && (fullDiff.isEmpty || changes.isEmpty) {
                Task {
                    let previous = currentPath
                    currentPath = ""
                    await load()
                    currentPath = previous
                }
            }
        }
    }

    private struct Crumb: Hashable {
        let title: String
        let path: String
    }

    private var breadcrumbItems: [Crumb] {
        var items = [Crumb(title: "repo", path: "")]
        if currentPath.isEmpty { return items }
        var accum = ""
        for part in currentPath.split(separator: "/").map(String.init) {
            accum = accum.isEmpty ? part : accum + "/" + part
            items.append(Crumb(title: part, path: accum))
        }
        return items
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(breadcrumbItems.enumerated()), id: \.element.path) { index, item in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Button {
                        currentPath = item.path
                        Task { await load() }
                    } label: {
                        Text(item.title)
                            .font(.system(size: 13, weight: item.path == currentPath ? .semibold : .regular))
                            .foregroundStyle(item.path == currentPath ? Theme.accent : Theme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                item.path == currentPath ? Theme.surfaceElevated : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .frame(height: 36)
    }

    private var filesList: some View {
        List {
            if !currentPath.isEmpty {
                Button {
                    currentPath = parentPath(currentPath)
                    Task { await load() }
                } label: {
                    Label("..", systemImage: "arrow.up.left")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            ForEach(entries, id: \.path) { entry in
                Button {
                    if entry.isDirectory {
                        currentPath = entry.path
                        Task { await load() }
                    } else {
                        selectedFile = SelectedFile(path: entry.path, preferDiff: entry.changeStatus != nil)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                            .foregroundStyle(entry.isDirectory ? Theme.accent : Theme.selection)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            if !entry.isDirectory {
                                Text(formatSize(entry.size))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        Spacer()
                        if let status = entry.changeStatus {
                            Text(status)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(statusColor(status))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(statusColor(status).opacity(0.15), in: Capsule())
                        }
                        if entry.isDirectory {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var diffsList: some View {
        List {
            if changes.isEmpty && fullDiff.isEmpty {
                Section {
                    Text(loading ? "Loading…" : "Working tree is clean.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                if !changes.isEmpty {
                    Section("Changed files") {
                        ForEach(changes, id: \.path) { change in
                            Button {
                                selectedFile = SelectedFile(path: change.path, preferDiff: true)
                            } label: {
                                HStack {
                                    Text(change.status)
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(statusColor(change.status))
                                        .frame(width: 20)
                                    Text(change.path)
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(2)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                    }
                }
                if !fullDiff.isEmpty {
                    Section("Unified diff") {
                        ColorizedDiffView(patch: fullDiff)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        guard let endpoint = state.serverEndpoint, let token = state.serverToken else {
            errorMessage = "Pair a desktop server first."
            return
        }
        do {
            let result = try await WorkspaceRPC.withConnection(
                endpoint: endpoint,
                token: token,
                send: { client in
                    try await client.send(.fileList(sessionId: sessionId, path: currentPath))
                },
                match: { msg -> (entries: [ServerMessage.FileEntryPayload], diff: String?, changes: [ServerMessage.FileChangePayload]?)? in
                    if case let .fileListResult(_, path, entries, diff, changes) = msg {
                        // Accept empty path / "." / requested path.
                        if path == currentPath || (currentPath.isEmpty && (path.isEmpty || path == ".")) {
                            return (entries, diff, changes)
                        }
                    }
                    if case let .error(_, message) = msg {
                        errorMessage = message
                    }
                    return nil
                }
            )
            entries = result.entries
            if let diff = result.diff { fullDiff = diff }
            if let changes = result.changes { self.changes = changes }
            // When browsing a subfolder, refresh root changes for Diffs tab once.
            if currentPath.isEmpty == false && changes.isEmpty {
                // keep previous root changes
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parentPath(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p == "." ? "" : p
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "A", "?": return .green
        case "D": return .red
        case "M", "R", "C": return .orange
        default: return Theme.selection
        }
    }
}

// MARK: - File viewer / editor (source + diff + save)

struct FileViewerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    let path: String
    var preferDiff: Bool = false

    @State private var content: String = ""
    @State private var originalContent: String = ""
    @State private var diff: String = ""
    @State private var loading = true
    @State private var saving = false
    @State private var truncated = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var tab: ViewerTab
    @State private var showMarkdownPreview = false
    @State private var showHTMLPreview = false

    enum ViewerTab: String, CaseIterable, Identifiable {
        case edit = "Edit"
        case diff = "Diff"
        var id: String { rawValue }
    }

    init(sessionId: String, path: String, preferDiff: Bool = false) {
        self.sessionId = sessionId
        self.path = path
        self.preferDiff = preferDiff
        _tab = State(initialValue: preferDiff ? .diff : .edit)
    }

    private var language: String? { CodeLanguage.detect(from: path) }
    private var isMarkdownFile: Bool { CodeLanguage.isMarkdown(path) }
    private var isHTMLFile: Bool { CodeLanguage.isHTML(path) }
    private var isDirty: Bool { content != originalContent }
    private var hasDiff: Bool { !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSave: Bool { isDirty && !saving && !truncated && !loading }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if hasDiff || preferDiff {
                    Picker("", selection: $tab) {
                        ForEach(availableTabs) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }

                Group {
                    if tab == .diff && hasDiff {
                        ScrollView([.horizontal, .vertical]) {
                            ColorizedDiffView(patch: diff)
                                .padding(12)
                        }
                    } else {
                        CodeEditorView(
                            text: $content,
                            language: language,
                            isEditable: !truncated
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if truncated {
                    Text("Truncated at 256 KB — editing disabled. Open on the desktop for the full file.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surfaceElevated)
                }

                previewBar
            }
            .background(Theme.background)
            .overlay { if loading { ProgressView() } }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                    }
                }
            }
            .interactiveDismissDisabled(isDirty && !saving)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .task { await load() }
        .sheet(isPresented: $showMarkdownPreview) {
            MarkdownPreviewSheet(markdown: content)
        }
        .sheet(isPresented: $showHTMLPreview) {
            HTMLPreviewSheet(html: content, title: (path as NSString).lastPathComponent)
        }
    }

    private var availableTabs: [ViewerTab] {
        hasDiff ? ViewerTab.allCases : [.edit]
    }

    @ViewBuilder
    private var previewBar: some View {
        if isMarkdownFile || isHTMLFile {
            HStack(spacing: 10) {
                if isMarkdownFile {
                    Button {
                        showMarkdownPreview = true
                    } label: {
                        Label("Preview Markdown", systemImage: "eye")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                }
                if isHTMLFile {
                    Button {
                        showHTMLPreview = true
                    } label: {
                        Label("Preview in browser", systemImage: "safari")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                }
                Spacer(minLength: 0)
                if isDirty {
                    Text("Unsaved")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface)
        }
    }

    private func load() async {
        defer { loading = false }
        guard let endpoint = state.serverEndpoint, let token = state.serverToken else {
            errorMessage = "Pair a desktop server first."
            return
        }
        do {
            let result = try await WorkspaceRPC.withConnection(
                endpoint: endpoint,
                token: token,
                send: { client in
                    try await client.send(.fileRead(sessionId: sessionId, path: path))
                },
                match: { msg -> (String, Bool, String?)? in
                    if case let .fileReadResult(_, p, content, truncated, diff) = msg, p == path {
                        return (content, truncated, diff)
                    }
                    if case let .error(_, message) = msg {
                        errorMessage = message
                    }
                    return nil
                }
            )
            content = result.0
            originalContent = result.0
            truncated = result.1
            diff = result.2 ?? ""
            if preferDiff && hasDiff {
                tab = .diff
            } else {
                tab = .edit
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        statusMessage = nil
        errorMessage = nil
        defer { saving = false }
        guard let endpoint = state.serverEndpoint, let token = state.serverToken else {
            errorMessage = "Pair a desktop server first."
            return
        }
        do {
            let result = try await WorkspaceRPC.withConnection(
                endpoint: endpoint,
                token: token,
                timeoutSeconds: 20,
                send: { client in
                    try await client.send(.fileWrite(sessionId: sessionId, path: path, content: content))
                },
                match: { msg -> (Bool, String?)? in
                    if case let .fileWriteResult(_, p, ok, message) = msg, p == path {
                        return (ok, message)
                    }
                    if case let .error(_, message) = msg {
                        errorMessage = message
                    }
                    return nil
                }
            )
            if result.0 {
                originalContent = content
                statusMessage = result.1 ?? "Saved."
                // Refresh diff after save so the Diff tab stays honest.
                await reloadDiffOnly()
            } else {
                errorMessage = result.1 ?? "Save failed."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadDiffOnly() async {
        guard let endpoint = state.serverEndpoint, let token = state.serverToken else { return }
        do {
            let result = try await WorkspaceRPC.withConnection(
                endpoint: endpoint,
                token: token,
                send: { client in
                    try await client.send(.fileRead(sessionId: sessionId, path: path))
                },
                match: { msg -> String? in
                    if case let .fileReadResult(_, p, _, _, diff) = msg, p == path {
                        return diff ?? ""
                    }
                    return nil
                }
            )
            diff = result
        } catch {
            // Soft-fail — content already saved.
        }
    }
}

/// Colorized unified-diff renderer used by the explorer Diffs tab and file viewer.
struct ColorizedDiffView: View {
    let patch: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line.isEmpty ? " " : line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color(for: String(line)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: String(line)))
                    .textSelection(.enabled)
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return Theme.textSecondary }
        if line.hasPrefix("@@") { return Theme.selection }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return Theme.textPrimary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color.green.opacity(0.12) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color.red.opacity(0.12) }
        if line.hasPrefix("@@") { return Theme.selection.opacity(0.12) }
        return .clear
    }
}

// MARK: - Open ports (web preview)

/// Lists listening ports on the desktop for this coding session. Preview
/// tunnels a port so the phone can reach a local web server. Remote-access
/// tunnels for the coding environment itself live in desktop Settings.
struct PortManagerView: View {
    let sessionId: String
    @EnvironmentObject var state: AppState
    @Environment(\.openURL) private var openURL

    @State private var ports: [ServerMessage.PortEntryPayload] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var busyPort: Int?
    @State private var lastPreviewURL: String?

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
            }

            if let lastPreviewURL {
                Section("Last preview") {
                    Button {
                        if let u = URL(string: lastPreviewURL) { openURL(u) }
                    } label: {
                        Text(lastPreviewURL)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }

            Section {
                if ports.isEmpty {
                    Text(loading ? "Scanning…" : "No listening ports found.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(ports, id: \.port) { entry in
                        portRow(entry)
                    }
                }
            } header: {
                Text("Listening on desktop")
            } footer: {
                Text("Preview opens this port on your phone via a short-lived public URL. Configure remote access for the coding server itself in the desktop app Settings.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await reloadPorts() }
        .task { await reloadPorts() }
        .overlay {
            if loading && ports.isEmpty { ProgressView() }
        }
    }

    @ViewBuilder
    private func portRow(_ entry: ServerMessage.PortEntryPayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(Theme.selection)
                VStack(alignment: .leading, spacing: 2) {
                    Text(":\(entry.port)")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                    Text("pid \(entry.pid) · \(entry.command)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            Button {
                Task { await preview(port: entry.port) }
            } label: {
                if busyPort == entry.port {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Preview on phone", systemImage: "safari")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(busyPort != nil)
        }
        .padding(.vertical, 4)
    }

    private func reloadPorts() async {
        loading = true
        defer { loading = false }
        guard let endpoint = state.serverEndpoint, let token = state.serverToken else {
            errorMessage = "Pair a desktop server first."
            return
        }
        do {
            let list = try await WorkspaceRPC.withConnection(
                endpoint: endpoint,
                token: token,
                send: { try await $0.send(.portList(sessionId: sessionId)) },
                match: { msg -> [ServerMessage.PortEntryPayload]? in
                    if case let .portListResult(_, ports) = msg { return ports }
                    return nil
                }
            )
            ports = list
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func preview(port: Int) async {
        busyPort = port
        defer { busyPort = nil }
        guard let endpoint = state.serverEndpoint, let token = state.serverToken else {
            errorMessage = "Pair a desktop server first."
            return
        }
        do {
            let status = try await WorkspaceRPC.withConnection(
                endpoint: endpoint,
                token: token,
                timeoutSeconds: 25,
                send: {
                    try await $0.send(.tunnelStart(
                        sessionId: sessionId,
                        port: port,
                        provider: "auto"
                    ))
                },
                match: { msg -> [ServerMessage.TunnelPayload]? in
                    if case let .tunnelStatus(_, tunnels, _) = msg { return tunnels }
                    if case let .error(_, message) = msg {
                        errorMessage = message
                    }
                    return nil
                }
            )
            if let url = status.first(where: { $0.port == port })?.url {
                lastPreviewURL = url
                if let u = URL(string: url) { openURL(u) }
                errorMessage = nil
            } else {
                errorMessage = "Tunnel started but no URL yet — pull to refresh and try again."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
