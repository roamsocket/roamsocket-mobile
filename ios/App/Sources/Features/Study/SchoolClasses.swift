import Foundation
import SwiftUI

/// What a document inside a class is for — drives grouping in the class
/// detail screen so the syllabus and assignments stay separate and tidy.
enum SchoolClassDocumentKind: String, Codable, CaseIterable {
    case syllabus
    case assignment
    case other

    var title: String {
        switch self {
        case .syllabus: return "Syllabus"
        case .assignment: return "Assignment"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .syllabus: return "doc.plaintext"
        case .assignment: return "doc.text"
        case .other: return "doc"
        }
    }
}

/// A single file attached to a class (syllabus, assignment, handout…).
/// The file itself is copied into the app's Documents directory; only the
/// stored name is persisted in the class JSON.
struct SchoolClassDocument: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: SchoolClassDocumentKind
    /// Display name — the original file name at import time.
    var originalFileName: String
    /// Name the file was stored under inside the class documents folder.
    var storedFileName: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: SchoolClassDocumentKind,
        originalFileName: String,
        storedFileName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.originalFileName = originalFileName
        self.storedFileName = storedFileName
        self.createdAt = createdAt
    }
}

/// One school class — the "project" of school mode. Holds a name, free-form
/// notes, and uploaded documents grouped by kind.
struct SchoolClass: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var notes: String
    var documents: [SchoolClassDocument]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        documents: [SchoolClassDocument] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.documents = documents
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Documents newest-first.
    var sortedDocuments: [SchoolClassDocument] {
        documents.sorted { $0.createdAt > $1.createdAt }
    }

    var syllabus: [SchoolClassDocument] {
        sortedDocuments.filter { $0.kind == .syllabus }
    }

    var assignments: [SchoolClassDocument] {
        sortedDocuments.filter { $0.kind == .assignment }
    }

    var otherDocuments: [SchoolClassDocument] {
        sortedDocuments.filter { $0.kind == .other }
    }
}

/// Persists school classes (name, notes, and document metadata) in
/// UserDefaults; the actual uploaded files live in the app's Documents
/// directory under `ClassDocuments/`, keyed by `storedFileName`.
final class SchoolClassStore: ObservableObject {
    static let shared = SchoolClassStore()

    @Published private(set) var classes: [SchoolClass] = []
    private let storageKey = "schoolClasses.v1"

    /// Folder inside Documents that holds every uploaded class file.
    private let filesDirectory: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        filesDirectory = documents.appendingPathComponent("ClassDocuments", isDirectory: true)
        try? FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        load()
    }

    /// Classes newest-activity first.
    var sortedClasses: [SchoolClass] {
        classes.sorted { $0.updatedAt > $1.updatedAt }
    }

    func schoolClass(withID id: UUID) -> SchoolClass? {
        classes.first(where: { $0.id == id })
    }

    @discardableResult
    func createClass(name: String, notes: String = "") -> SchoolClass {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let klass = SchoolClass(name: trimmedName.isEmpty ? "New class" : trimmedName, notes: notes)
        classes.insert(klass, at: 0)
        save()
        return klass
    }

    /// Insert or replace a class by id. Touches `updatedAt` so it bubbles to
    /// the top of the list when documents or notes change.
    @discardableResult
    func upsertClass(_ klass: SchoolClass) -> SchoolClass {
        var updated = klass
        updated.updatedAt = Date()
        if let idx = classes.firstIndex(where: { $0.id == klass.id }) {
            classes[idx] = updated
        } else {
            classes.insert(updated, at: 0)
        }
        save()
        return updated
    }

    func renameClass(id: UUID, name: String) {
        guard let idx = classes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        classes[idx].name = trimmed
        classes[idx].updatedAt = Date()
        save()
    }

    func updateNotes(id: UUID, notes: String) {
        guard let idx = classes.firstIndex(where: { $0.id == id }) else { return }
        classes[idx].notes = notes
        classes[idx].updatedAt = Date()
        save()
    }

    /// Copies a security-scoped file (from `fileImporter`) into the class
    /// documents folder and attaches it to the class. Returns the created
    /// document, or nil if the copy failed.
    @discardableResult
    func addDocument(
        to classID: UUID,
        from sourceURL: URL,
        kind: SchoolClassDocumentKind
    ) -> SchoolClassDocument? {
        let secured = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if secured { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let storedName = "\(UUID().uuidString).\(sourceURL.pathExtension)"
        let destination = filesDirectory.appendingPathComponent(storedName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            return nil
        }

        let displayName = sourceURL.lastPathComponent.isEmpty
            ? "Untitled"
            : sourceURL.lastPathComponent
        let document = SchoolClassDocument(
            kind: kind,
            originalFileName: displayName,
            storedFileName: storedName
        )
        guard let idx = classes.firstIndex(where: { $0.id == classID }) else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        classes[idx].documents.append(document)
        classes[idx].updatedAt = Date()
        save()
        return document
    }

    func deleteDocument(classID: UUID, documentID: UUID) {
        guard let idx = classes.firstIndex(where: { $0.id == classID }) else { return }
        let removed = classes[idx].documents.first(where: { $0.id == documentID })
        classes[idx].documents.removeAll { $0.id == documentID }
        classes[idx].updatedAt = Date()
        if let removed {
            try? FileManager.default.removeItem(at: filesDirectory.appendingPathComponent(removed.storedFileName))
        }
        save()
    }

    func deleteClass(id: UUID) {
        guard let klass = classes.first(where: { $0.id == id }) else { return }
        for document in klass.documents {
            try? FileManager.default.removeItem(at: filesDirectory.appendingPathComponent(document.storedFileName))
        }
        classes.removeAll { $0.id == id }
        save()
    }

    /// Resolves an uploaded document back to a readable file URL.
    func fileURL(for document: SchoolClassDocument) -> URL? {
        let url = filesDirectory.appendingPathComponent(document.storedFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([SchoolClass].self, from: data)
        else { return }
        classes = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(classes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
