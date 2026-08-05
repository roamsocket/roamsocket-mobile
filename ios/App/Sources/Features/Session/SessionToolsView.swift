import SwiftUI
import MobileAICore
import Combine

/// Sheet that hosts the in-session tools: a terminal that runs in the
/// session's workdir, a file explorer with diffs, and a port manager that
/// surfaces dev servers the agent has started.
struct SessionToolsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .terminal

    enum Tab: String, CaseIterable, Identifiable {
        case terminal = "Terminal"
        case files = "Files"
        case ports = "Ports"
        var id: String { rawValue }
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
                case .terminal: TerminalPaneView()
                case .files: FileExplorerView()
                case .ports: PortManagerView()
                }
            }
            .background(Theme.background)
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Terminal

@MainActor
final class TerminalViewModel: ObservableObject {
    @Published var output: String = ""
    @Published var isRunning: Bool = false
    @Published var exitCode: Int?

    private var terminalId: String?
    private var streamTask: Task<Void, Never>?
    private weak var client: ServerClient?
    private weak var state: AppState?
    private let sessionId: String

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func start(state: AppState) {
        guard streamTask == nil else { return }
        self.state = state
        self.client = state.serverClient
        isRunning = true
        streamTask = Task { await run() }
    }

    func stop() {
        if let id = terminalId {
            Task { try? await state?.serverClient.send(.terminalKill(terminalId: id)) }
        }
        streamTask?.cancel()
        streamTask = nil
        isRunning = false
    }

    func send(_ text: String) {
        guard let id = terminalId, let client else { return }
        Task { try? await client.send(.terminalInput(terminalId: id, data: text)) }
    }

    private func run() async {
        // Open a fresh session-scoped WebSocket so the terminal survives
        // when the agent session is closed.
        guard let state, let endpoint = state.serverEndpoint, let token = state.serverToken else { return }
        do {
            let stream = try await client?.connect(endpoint: endpoint, token: token)
            try await client?.send(.terminalOpen(terminalId: nil, sessionId: sessionId))
            // Wait for `terminal_control(ready)` to learn the id.
            for await message in stream ?? AsyncStream { _ in } {
                if Task.isCancelled { return }
                handle(message)
            }
        } catch {
            isRunning = false
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case let .terminalControl(id, event, code):
            if event == "ready" {
                self.terminalId = id
            } else if event == "exit" {
                self.exitCode = code
                self.isRunning = false
            }
        case let .terminalData(_, stream, data):
            if stream == "err" {
                output += data
            } else {
                output += data
            }
        default: break
        }
    }
}

struct TerminalPaneView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = TerminalViewModel(sessionId: "")
    @State private var input: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.output.isEmpty ? "Terminal idle. Type a command and press Return." : model.output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("__bottom__")
                }
                .onChange(of: model.output) { _, _ in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("$", text: $input)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                Button("Run") {
                    model.send(input + "\n")
                    input = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .padding(8)
        }
        .onAppear {
            // Pull the active session id from AppState — for now, the
            // shell opens in the most recently created session's workdir.
            if let session = state.serverName {
                _ = session // no-op; placeholder until SessionView shares its id
            }
            model.start(state: state)
        }
        .onDisappear { model.stop() }
    }
}

// MARK: - File explorer

struct FileExplorerView: View {
    @EnvironmentObject var state: AppState
    @State private var entries: [ServerMessage.FileEntryPayload] = []
    @State private var diff: String?
    @State private var currentPath: String = ""
    @State private var loading = false
    @State private var selectedFile: SelectedFile?

    struct SelectedFile: Identifiable {
        let id = UUID()
        let path: String
    }

    var body: some View {
        List {
            if currentPath.isEmpty, let diff, !diff.isEmpty {
                Section("Changes vs base") {
                    Text(diff)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Section(currentPath.isEmpty ? "Repo root" : currentPath) {
                ForEach(entries, id: \.path) { entry in
                    Button {
                        if entry.isDirectory {
                            currentPath = entry.path
                            load()
                        } else {
                            selectedFile = SelectedFile(path: entry.path)
                        }
                    } label: {
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                                .foregroundStyle(Theme.selection)
                            Text(entry.name)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if !entry.isDirectory {
                                Text(formatSize(entry.size))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                }
                if !currentPath.isEmpty {
                    Button {
                        currentPath = (currentPath as NSString).deletingLastPathComponent
                        load()
                    } label: {
                        Label("..", systemImage: "arrow.up.left")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if loading { ProgressView() }
        }
        .sheet(item: $selectedFile) { file in
            FileViewerSheet(path: file.path)
        }
        .onAppear { load() }
    }

    private func load() {
        loading = true
        Task {
            defer { loading = false }
            guard let sessionId = state.serverName else { return }
            do {
                let stream = try await state.serverClient.connect(
                    endpoint: state.serverEndpoint!,
                    token: state.serverToken!
                )
                try await state.serverClient.send(.fileList(sessionId: sessionId, path: currentPath))
                for await msg in stream {
                    if case let .fileListResult(_, path, entries, diff) = msg {
                        if path == currentPath {
                            self.entries = entries
                            self.diff = diff
                        }
                        break
                    }
                }
            } catch { /* ignore */ }
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

struct FileViewerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var content: String = ""
    @State private var loading = true
    @State private var truncated: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Theme.background)
            .overlay {
                if loading { ProgressView() }
                if truncated {
                    VStack {
                        Spacer()
                        Text("Truncated at 256 KB. Open on the desktop for the full file.")
                            .font(.footnote)
                            .padding(8)
                            .background(Theme.surfaceElevated, in: Capsule())
                            .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        guard let sessionId = state.serverName,
              let endpoint = state.serverEndpoint,
              let token = state.serverToken else { return }
        do {
            let stream = try await state.serverClient.connect(endpoint: endpoint, token: token)
            try await state.serverClient.send(.fileRead(sessionId: sessionId, path: path))
            for await msg in stream {
                if case let .fileReadResult(_, p, content, truncated) = msg, p == path {
                    self.content = content
                    self.truncated = truncated
                    break
                }
            }
        } catch { /* ignore */ }
    }
}

// MARK: - Port manager

struct PortManagerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openURL) private var openURL
    @State private var ports: [ServerMessage.PortEntryPayload] = []
    @State private var loading = false

    var body: some View {
        List {
            if ports.isEmpty {
                Section {
                    Text(loading ? "Scanning…" : "No listening ports found.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Section {
                    ForEach(ports, id: \.port) { entry in
                        Button {
                            openURL(URL(string: "http://localhost:\(entry.port)")!)
                        } label: {
                            HStack {
                                Image(systemName: "network")
                                    .foregroundStyle(Theme.selection)
                                VStack(alignment: .leading) {
                                    Text("localhost:\(entry.port)")
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("pid \(entry.pid) · \(entry.command)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                } footer: {
                    Text("Tap to open in the system browser.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        guard let sessionId = state.serverName,
              let endpoint = state.serverEndpoint,
              let token = state.serverToken else { return }
        do {
            let stream = try await state.serverClient.connect(endpoint: endpoint, token: token)
            try await state.serverClient.send(.portList(sessionId: sessionId))
            for await msg in stream {
                if case let .portListResult(_, ports) = msg {
                    self.ports = ports
                    break
                }
            }
        } catch { /* ignore */ }
    }
}
