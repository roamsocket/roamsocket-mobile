import SwiftUI

/// Projects list screen, mirroring the second screenshot.
struct ProjectsListView: View {
    @ObservedObject var history: ChatHistoryStore
    @State private var search: String = ""

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                List {
                    ForEach(filtered) { project in
                        NavigationLink(value: RootRoute.projectDetail(project)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.name)
                                        .font(.system(size: 17, weight: .regular))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(relativeTime(project.updatedAt))
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .listRowBackground(Theme.background)
                        .listRowSeparatorTint(Theme.separator)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)

                searchBar
                newProjectButton
            }
        }
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {}) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Theme.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var filtered: [ProjectItem] {
        guard !search.isEmpty else { return history.projects }
        return history.projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search", text: $search)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var newProjectButton: some View {
        HStack {
            Spacer()
            Button(action: { history.createProject() }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text("New project")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.bottom, 24)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Catch-all placeholder for the top-level destinations (Artifacts / Code /
/// Dispatch) until those features ship.
struct PlaceholderListView: View {
    let title: String
    let systemImage: String

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Coming soon")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
