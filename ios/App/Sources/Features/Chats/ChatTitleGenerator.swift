import Foundation

/// Suggests short chat titles via **Lightweight Tasks** (Apple Intelligence
/// or a user-linked model). Falls back to a truncated first user message.
enum ChatTitleGenerator {
    static let defaultTitle = "New chat"
    static let maxTitleLength = 48

    /// Whether Apple Intelligence can run title generation right now.
    static var isOnDeviceAvailable: Bool {
        LightweightTaskRunner.appleFoundationAvailable
    }

    /// Build a display title from chat turns.
    static func suggestTitle(
        userMessages: [String],
        assistantMessages: [String] = []
    ) async -> String? {
        let heuristic = heuristicTitle(from: userMessages)
        guard let firstUser = userMessages
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        let system = """
        You name chat conversations for a coding assistant app.
        Reply with ONLY a short title: 2 to 6 words.
        No quotes, no trailing punctuation, no emoji, no explanation.
        Capture the topic; prefer nouns over full sentences.
        """

        var body = "User: \(clip(firstUser, limit: 500))"
        for msg in userMessages.dropFirst().prefix(2) {
            body += "\nUser: \(clip(msg, limit: 200))"
        }
        for msg in assistantMessages.prefix(2) {
            body += "\nAssistant: \(clip(msg, limit: 200))"
        }
        body += "\n\nTitle:"

        if let generated = await LightweightTaskRunner.complete(
            system: system,
            user: body,
            maxTokens: 24
        ), let clean = sanitize(generated) {
            return clean
        }

        return heuristic
    }

    static func heuristicTitle(from userMessages: [String]) -> String? {
        guard let first = userMessages
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        if first.count <= maxTitleLength { return first }
        return String(first.prefix(maxTitleLength - 1)) + "…"
    }

    static func sanitize(_ raw: String) -> String? {
        var text = ThinkingExtractor.plainVisibleText(from: raw)
        guard !text.isEmpty else { return nil }

        if let newline = text.firstIndex(of: "\n") {
            text = String(text[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let wrappers: [Character] = ["\"", "'", "`", "*", "“", "”", "‘", "’"]
        while let first = text.first, let last = text.last,
              wrappers.contains(first), wrappers.contains(last),
              text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if text.hasSuffix("."), text.count <= 40, !text.dropLast().contains(".") {
            text = String(text.dropLast())
        }

        guard !text.isEmpty else { return nil }
        if text.count <= maxTitleLength { return text }
        return String(text.prefix(maxTitleLength - 1)) + "…"
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
