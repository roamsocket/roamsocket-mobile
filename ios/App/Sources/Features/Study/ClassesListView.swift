import SwiftUI

/// School mode home for classes: one card per class, mirroring the Projects
/// list. Each class opens a detail screen where the syllabus, assignments,
/// and other documents can be uploaded and organized.
struct ClassesListView: View {
    @ObservedObject private var store = SchoolClassStore.shared
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
                        ForEach(filtered) { klass in
                            classCard(klass)
                                .background {
                                    // Invisible link keeps the disclosure chevron off the card.
                                    NavigationLink(value: RootRoute.classDetail(klass.id)) {
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
                        newClassButton
                        searchBar
                    }
                    .padding(.bottom, 24)
                }
                .frame(height: 140)
            }
        }
        .navigationTitle("Classes")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCreateSheet) {
            CreateClassSheet { name, notes in
                store.createClass(name: name, notes: notes)
            }
        }
    }

    private var filtered: [SchoolClass] {
        guard !search.isEmpty else { return store.sortedClasses }
        return store.sortedClasses.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.notes.localizedCaseInsensitiveContains(search)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No classes yet",
            systemImage: "book.closed",
            description: Text("Create a class and upload its syllabus and assignments.")
        )
        .foregroundStyle(Theme.textSecondary)
    }

    private func classCard(_ klass: SchoolClass) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(klass.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(relativeTime(klass.updatedAt))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    if !klass.documents.isEmpty {
                        Text("·")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                        Text("\(klass.documents.count) file\(klass.documents.count == 1 ? "" : "s")")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
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

    private var newClassButton: some View {
        HStack {
            Spacer()
            Button(action: { showCreateSheet = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text("New class")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Theme.inkOnAccent)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Theme.accent, in: Capsule())
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

/// "Add a class" bottom sheet — name plus optional notes, checked off on save.
private struct CreateClassSheet: View {
    var onCreate: (_ name: String, _ notes: String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var notes: String = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, notes }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        nameSection
                        notesSection
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .onAppear { focusedField = .name }
    }

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("New class")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Button(action: submit) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(canSubmit ? Theme.inkOnAccent : Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .background(
                        canSubmit ? Theme.accent : Theme.surfaceElevated,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What class is this?")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
            TextField("e.g. Calculus II", text: $name)
                .focused($focusedField, equals: .name)
                .submitLabel(.next)
                .onSubmit { focusedField = .notes }
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes (optional)")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Theme.surface)
                if notes.isEmpty {
                    Text("Room number, professor, office hours…")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                }
                TextEditor(text: $notes)
                    .focused($focusedField, equals: .notes)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(minHeight: 110)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        onCreate(
            name.trimmingCharacters(in: .whitespacesAndNewlines),
            notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        dismiss()
    }
}
