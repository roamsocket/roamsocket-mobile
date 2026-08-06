import Foundation

/// A captured chat artifact — anything the assistant produced that the user
/// might want to revisit (long outputs, code blocks, full reports).
public struct Artifact: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    /// The chat history id this artifact came from (for cross-reference).
    public let chatId: UUID?
    /// Short label, derived from the first line of the content.
    public var title: String
    /// Full markdown content as returned by the assistant.
    public var content: String
    /// Number of lines used to decide whether to save.
    public var lineCount: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        chatId: UUID? = nil,
        title: String,
        content: String,
        lineCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.chatId = chatId
        self.title = title
        self.content = content
        self.lineCount = lineCount
    }
}

/// Persists `Artifact` items to UserDefaults. Lightweight on purpose — these
/// are local-only views of chat output, not source-of-truth data.
public final class ArtifactStore: ObservableObject, @unchecked Sendable {
    @Published public private(set) var artifacts: [Artifact] = []

    private let storageKey = "artifacts.v1"

    public init() {
        load()
    }

    /// Save an artifact if it meets the criteria (currently: ≥ 10 lines OR
    /// contains a code block). Idempotent for the same content+chat.
    @discardableResult
    public func maybeSave(chatId: UUID?, content: String) -> Artifact? {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let containsCodeBlock = content.contains("```")
        guard lines >= 10 || containsCodeBlock else { return nil }
        // De-dupe identical artifacts from the same chat.
        if artifacts.contains(where: { $0.chatId == chatId && $0.content == content }) {
            return nil
        }
        let artifact = Artifact(
            chatId: chatId,
            title: Self.deriveTitle(from: content),
            content: content,
            lineCount: lines
        )
        artifacts.insert(artifact, at: 0)
        save()
        return artifact
    }

    public func delete(_ id: UUID) {
        artifacts.removeAll { $0.id == id }
        save()
    }

    public func clearAll() {
        artifacts.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Artifact].self, from: data)
        else { return }
        artifacts = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(artifacts) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Use the first non-empty line as the title; fall back to "Artifact".
    private static func deriveTitle(from content: String) -> String {
        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Skip markdown heading markers, but keep the text.
            let cleaned = line.hasPrefix("#") ? String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) : line
            // Skip code fences.
            if cleaned.hasPrefix("```") { continue }
            if !cleaned.isEmpty { return String(cleaned.prefix(80)) }
        }
        return "Artifact"
    }
}
