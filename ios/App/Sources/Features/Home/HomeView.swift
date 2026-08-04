import SwiftUI
import MobileAICore

/// The composer / home screen (IMG_0987): suggestions, repo chip, input, and
/// the bottom control row (model pill, permission pill, mic, send).
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @State private var prompt: String = ""
    @State private var activeSheet: HomeSheet?
    @State private var startedSession: SessionConfig?

    private let suggestions: [(String, [String])] = [
        ("Create or update my CLAUDE.md file", ["CLAUDE.md"]),
        ("Search for a TODO comment and fix it", ["TODO"]),
        ("Recommend areas to improve our tests", []),
    ]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Suggestions")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.top, 8)

                        ForEach(suggestions, id: \.0) { text, tokens in
                            SuggestionCard(attributed: highlight(text, tokens: tokens)) {
                                prompt = text
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                composer
            }
        }
        .navigationDestination(item: $startedSession) { config in
            SessionView(config: config)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .model: ModelPickerSheet()
            case .environment: EnvironmentPickerSheet()
            case .repository: RepositoryPickerSheet()
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 12) {
            // Repo chip row (IMG_0987)
            HStack(spacing: 12) {
                Button {
                    activeSheet = .environment
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    activeSheet = .repository
                } label: {
                    HStack(spacing: 8) {
                        GitHubGlyph()
                        Text(state.selectedRepo?.fullName ?? "Choose repository")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Theme.surfaceElevated, in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }

            // Input + controls container
            VStack(alignment: .leading, spacing: 14) {
                TextField("", text: $prompt, prompt: Text("Describe a task…").foregroundColor(Theme.textTertiary), axis: .vertical)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...6)
                    .tint(Theme.accent)

                HStack(spacing: 10) {
                    Pill(title: modelPillTitle, action: { activeSheet = .model })
                    Pill(title: state.permissionMode.displayName,
                         systemImage: "chevron.left.forwardslash.chevron.right",
                         action: cyclePermissionMode)
                    Spacer(minLength: 0)
                    Image(systemName: "mic")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 40, height: 40)
                    sendButton
                }
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
        }
        .padding(16)
        .background(Theme.background)
    }

    private var sendButton: some View {
        Button(action: startSession) {
            Image(systemName: "arrow.up")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(canSend ? Theme.accent : Theme.surfaceElevated, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    private var modelPillTitle: String {
        state.selectedModel?.displayName ?? "Select model"
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.selectedRepo != nil
    }

    private func cyclePermissionMode() {
        let modes = PermissionMode.allCases
        if let idx = modes.firstIndex(of: state.permissionMode) {
            state.permissionMode = modes[(idx + 1) % modes.count]
        }
    }

    private func startSession() {
        guard let repo = state.selectedRepo,
              let model = state.modelSelectionForSession(),
              let endpoint = state.serverEndpoint,
              let token = state.serverToken
        else {
            activeSheet = state.serverToken == nil ? nil : .repository
            return
        }
        let workBranch = "cmai/\(slug(prompt))"
        startedSession = SessionConfig(
            endpoint: endpoint,
            token: token,
            repo: RepoRef(
                fullName: repo.fullName,
                baseBranch: repo.defaultBranch,
                workBranch: workBranch,
                githubToken: state.githubToken
            ),
            environment: state.selectedEnvironment,
            model: model,
            permissionMode: state.permissionMode,
            firstMessage: prompt
        )
        prompt = ""
    }

    private func slug(_ text: String) -> String {
        let base = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(5)
            .joined(separator: "-")
        return base.isEmpty ? "task-\(Int(Date().timeIntervalSince1970))" : base
    }

    /// Build an attributed string with accent-colored monospace tokens.
    private func highlight(_ text: String, tokens: [String]) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = Theme.textPrimary
        for token in tokens {
            if let range = attributed.range(of: token) {
                attributed[range].foregroundColor = Theme.codeToken
                attributed[range].font = .system(size: 18, design: .monospaced)
            }
        }
        return attributed
    }
}

enum HomeSheet: String, Identifiable {
    case model, environment, repository
    var id: String { rawValue }
}
