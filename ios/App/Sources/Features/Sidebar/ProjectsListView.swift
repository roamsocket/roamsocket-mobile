import SwiftUI

/// Projects list — compact card rows (iOS 26–style inset surfaces).
struct ProjectsListView: View {
    @ObservedObject var history: ChatHistoryStore
    @State private var search: String = ""
    @State private var showCreateSheet: Bool = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                if filtered.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered) { project in
                            projectCard(project)
                                .background {
                                    // Invisible link keeps the system disclosure chevron off the card.
                                    NavigationLink(value: RootRoute.projectDetail(project)) {
                                        EmptyView()
                                    }
                                    .opacity(0)
                                }
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }

                // Bottom-of-screen stack: Search bar sits below the FAB.
                ZStack(alignment: .top) {
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

    private var emptyState: some View {
        ContentUnavailableView(
            "No projects yet",
            systemImage: "tray",
            description: Text("Create a project to organize chats.")
        )
        .foregroundStyle(Theme.textSecondary)
    }

    private func projectCard(_ project: ProjectItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(relativeTime(project.updatedAt))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.separator.opacity(0.55), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
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
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
