import SwiftUI
import QuickLook
import UniformTypeIdentifiers

/// One class: editable notes plus uploaded documents grouped into Syllabus,
/// Assignments, and Other. Files come in through the system file picker and
/// are copied into the app's storage by `SchoolClassStore`.
struct ClassDetailView: View {
    @ObservedObject private var store = SchoolClassStore.shared
    let classID: UUID

    @State private var klass: SchoolClass = SchoolClass(name: "")
    @State private var notes: String = ""
    @State private var showRename = false
    @State private var renameTitle = ""
    @State private var pendingKind: SchoolClassDocumentKind?
    @State private var showFilePicker = false
    @State private var previewItem: PreviewItem?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    notesSection
                    syllabusSection
                    assignmentsSection
                    otherSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(klass.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    renameTitle = klass.name
                    showRename = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .accessibilityLabel("Rename class")
            }
        }
        .onAppear { loadClass() }
        .onChange(of: classID) { _, _ in loadClass() }
        .onDisappear { saveNotes() }
        .alert("Rename class", isPresented: $showRename) {
            TextField("Class name", text: $renameTitle)
            Button("Save") {
                store.renameClass(id: classID, name: renameTitle)
                loadClass()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this class a name you'll recognize.")
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item]
        ) { result in
            handleImport(result, kind: pendingKind ?? .other)
            pendingKind = nil
        }
        .sheet(item: $previewItem) { item in
            ClassDocumentPreview(url: item.url)
                .ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    Button {
                        previewItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.textTertiary)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .padding(.trailing, 16)
                }
                .presentationDetents([.large])
        }
    }

    // MARK: - Sections

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.surface)
                if notes.isEmpty {
                    Text("Room, professor, office hours, deadlines…")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                TextEditor(text: $notes)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 90)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.separator.opacity(0.55), lineWidth: 1)
            )
        }
    }

    private var syllabusSection: some View {
        documentSection(
            title: "Syllabus",
            documents: klass.syllabus,
            kind: .syllabus,
            emptyHint: "Upload the course syllabus so it's always one tap away."
        )
    }

    private var assignmentsSection: some View {
        documentSection(
            title: "Assignments",
            documents: klass.assignments,
            kind: .assignment,
            emptyHint: "Add assignment sheets, rubrics, and handouts."
        )
    }

    private var otherSection: some View {
        documentSection(
            title: "Other documents",
            documents: klass.otherDocuments,
            kind: .other,
            emptyHint: "Study guides, schedules, notes — anything else for this class."
        )
    }

    private func documentSection(
        title: String,
        documents: [SchoolClassDocument],
        kind: SchoolClassDocumentKind,
        emptyHint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    pendingKind = kind
                    showFilePicker = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            if documents.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(documents) { document in
                        documentRow(document)
                    }
                }
            }
        }
    }

    private func documentRow(_ document: SchoolClassDocument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: document.kind.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(document.originalFileName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(document.createdAt, style: .date)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 8)

            if let url = store.fileURL(for: document) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share \(document.originalFileName)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.separator.opacity(0.55), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onTapGesture {
            if let url = store.fileURL(for: document) {
                previewItem = PreviewItem(url: url)
            }
        }
        .contextMenu {
            Button {
                if let url = store.fileURL(for: document) {
                    previewItem = PreviewItem(url: url)
                }
            } label: {
                Label("Preview", systemImage: "eye")
            }
            Button(role: .destructive) {
                store.deleteDocument(classID: classID, documentID: document.id)
                loadClass()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Helpers

    private func loadClass() {
        if let found = store.schoolClass(withID: classID) {
            klass = found
            notes = found.notes
        }
    }

    private func saveNotes() {
        guard store.schoolClass(withID: classID) != nil else { return }
        store.updateNotes(id: classID, notes: notes)
    }

    private func handleImport(_ result: Result<URL, Error>, kind: SchoolClassDocumentKind) {
        guard case .success(let url) = result else { return }
        saveNotes()
        store.addDocument(to: classID, from: url, kind: kind)
        loadClass()
    }
}

/// Tappable preview target for a class document.
private struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Hosts a QuickLook preview for an uploaded class document.
private struct ClassDocumentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
