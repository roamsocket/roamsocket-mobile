import SwiftUI

/// Projects list screen, mirroring the second screenshot.
struct ProjectsListView: View {
    @ObservedObject var history: ChatHistoryStore
    @State private var search: String = ""
    @State private var showCreateSheet: Bool = false

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

                // Bottom-of-screen stack: Search bar sits below the FAB.
                // The FAB (New project) is right-aligned and floats above
                // the search bar, matching the search layout.
                ZStack(alignment: .top) {
                    // Background strip so the search bar has a solid
                    // background under the FAB shadow.
                    Theme.background
                        .ignoresSafeArea(edges: .bottom)

                    VStack(spacing: 12) {
                        newProjectButton
                        searchBar
                    }
                    .padding(.bottom, 24)
                }
                .frame(height: 140)
            }
        }
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCreateSheet) {
            CreateProjectSheet { name, description in
                history.createProject(name: name, description: description)
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
    }

    private var newProjectButton: some View {
        HStack {
            Spacer()
            Button(action: { showCreateSheet = true }) {
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
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
