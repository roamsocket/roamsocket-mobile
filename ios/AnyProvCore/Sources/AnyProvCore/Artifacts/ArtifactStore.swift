import Foundation

/// A captured chat artifact — anything the assistant produced that the user
/// might want to revisit (long outputs, code blocks, full reports).
public struct Artifact: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    /// The chat history id this artifact came from (for cross-reference).
    public let chatId: UUID?
    /// Assistant message id that produced this artifact (scroll target).
    public let messageId: UUID?
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
        messageId: UUID? = nil,
        title: String,
        content: String,
        lineCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.chatId = chatId
        self.messageId = messageId
        self.title = title
        self.content = content
        self.lineCount = lineCount
    }

    enum CodingKeys: String, CodingKey {
        case id, createdAt, chatId, messageId, title, content, lineCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        chatId = try c.decodeIfPresent(UUID.self, forKey: .chatId)
        messageId = try c.decodeIfPresent(UUID.self, forKey: .messageId)
        title = try c.decode(String.self, forKey: .title)
        content = try c.decode(String.self, forKey: .content)
        lineCount = try c.decode(Int.self, forKey: .lineCount)
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
    /// contains a code block). Idempotent for the same content+chat / message.
    /// - Parameter title: Optional display name (e.g. Foundation Model suggestion).
    ///   When omitted, uses a first-line heuristic until a better title is applied.
    @discardableResult
    public func maybeSave(
        chatId: UUID?,
        messageId: UUID? = nil,
        content: String,
        title: String? = nil
    ) -> Artifact? {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let containsCodeBlock = content.contains("```")
        guard lines >= 10 || containsCodeBlock else { return nil }
        let resolvedTitle = {
            let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? Self.deriveTitle(from: content) : t
        }()
        // Update existing capture from the same assistant message.
        if let messageId,
           let idx = artifacts.firstIndex(where: { $0.messageId == messageId }) {
            var updated = artifacts[idx]
            updated.content = content
            // Keep a Foundation-named title if content is only refined mid-stream
            // and the caller didn't pass a new title.
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.title = resolvedTitle
            } else if updated.title == "Artifact" || updated.title.isEmpty {
                updated.title = resolvedTitle
            }
            updated.lineCount = lines
            artifacts[idx] = updated
            save()
            return updated
        }
        // De-dupe identical artifacts from the same chat.
        if artifacts.contains(where: { $0.chatId == chatId && $0.content == content }) {
            return nil
        }
        let artifact = Artifact(
            chatId: chatId,
            messageId: messageId,
            title: resolvedTitle,
            content: content,
            lineCount: lines
        )
        artifacts.insert(artifact, at: 0)
        save()
        return artifact
    }

    /// Replace the display title (e.g. after on-device Foundation Model naming).
    @discardableResult
    public func updateTitle(id: UUID, title: String) -> Artifact? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let idx = artifacts.firstIndex(where: { $0.id == id }) else { return nil }
        artifacts[idx].title = trimmed
        save()
        return artifacts[idx]
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
