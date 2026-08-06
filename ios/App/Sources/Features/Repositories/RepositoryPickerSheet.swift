import SwiftUI
import AnyProvCore

/// The "Choose repository" bottom sheet (IMG_0991): a searchable repo list.
struct RepositoryPickerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var repos: [GitHubRepo] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var showGitHubLink = false

    private var isGitHubLinked: Bool {
        state.githubToken?.isEmpty == false
    }

    private var filtered: [GitHubRepo] {
        guard !search.isEmpty else { return repos }
        return repos.filter { $0.fullName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        SheetScaffold(title: "Choose repository", trailing: nil, onClose: { dismiss() }) {
            VStack(spacing: 0) {
                if !isGitHubLinked {
                    notLinked
                } else if loading {
                    ProgressView().tint(Theme.textSecondary).padding(.vertical, 40)
                    Spacer()
                } else if let error {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .padding()
                    Spacer()
                } else {
                    list
                }

                if isGitHubLinked {
                    searchField
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showGitHubLink, onDismiss: {
            if isGitHubLinked {
                Task { await load(force: true) }
            }
        }) {
            NavigationStack { GitHubLinkView() }
        }
        .task { await load() }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(filtered) { repo in
                    SelectableRow(
                        title: repo.name,
                        subtitle: repo.owner,
                        isSelected: state.selectedRepo?.fullName == repo.fullName
                    ) {
                        state.selectedRepo = repo
                        dismiss()
                    }
                    Divider().overlay(Theme.separator)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textTertiary)
            TextField("", text: $search, prompt: Text("Search").foregroundColor(Theme.textTertiary))
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.surfaceElevated, in: Capsule())
        .padding(16)
    }

    private var notLinked: some View {
        VStack(spacing: 16) {
            Text("Link GitHub to choose a repository")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Sign in with GitHub or paste a personal access token to load your repositories.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showGitHubLink = true
            } label: {
                Text("Link GitHub")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(30)
        .frame(maxHeight: .infinity)
    }

    private func load(force: Bool = false) async {
        guard let token = state.githubToken, !token.isEmpty else { return }
        if !force, !repos.isEmpty { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let client = GitHubClient(clientID: state.githubClientID)
            repos = try await client.listRepos(token: token)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
