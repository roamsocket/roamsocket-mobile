import SwiftUI
import MobileAICore

/// The "Choose repository" bottom sheet (IMG_0991): a searchable repo list.
struct RepositoryPickerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var repos: [GitHubRepo] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?

    private var filtered: [GitHubRepo] {
        guard !search.isEmpty else { return repos }
        return repos.filter { $0.fullName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        SheetScaffold(title: "Choose repository", trailing: nil, onClose: { dismiss() }) {
            VStack(spacing: 0) {
                if state.githubToken == nil {
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

                searchField
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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
        VStack(spacing: 12) {
            Text("Link GitHub to choose a repository")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Open Settings to sign in with GitHub or paste a personal access token.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxHeight: .infinity)
    }

    private func load() async {
        guard let token = state.githubToken, repos.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let client = GitHubClient(clientID: state.githubClientID)
            repos = try await client.listRepos(token: token)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
