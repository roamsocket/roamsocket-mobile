import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Suggests short chat titles using Apple's on-device Foundation Model when
/// available (iOS 26+ / Apple Intelligence). Falls back to a truncated first
/// user message so naming still works offline and on older OS versions.
enum ChatTitleGenerator {
    static let defaultTitle = "New chat"
    static let maxTitleLength = 48

    /// Whether the on-device Apple Intelligence model can run title generation.
    static var isOnDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Build a display title from chat turns.
    /// Prefers Foundation Models; otherwise returns the heuristic title.
    static func suggestTitle(
        userMessages: [String],
        assistantMessages: [String] = []
    ) async -> String? {
        let heuristic = heuristicTitle(from: userMessages)
        guard let firstUser = userMessages
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let generated = await generateWithFoundationModel(
                firstUser: firstUser,
                moreUsers: Array(userMessages.dropFirst().prefix(2)),
                assistants: Array(assistantMessages.prefix(2))
            ) {
                return generated
            }
        }
        #endif

        return heuristic
    }

    /// Truncate the first non-empty user message (sidebar fallback).
    static func heuristicTitle(from userMessages: [String]) -> String? {
        guard let first = userMessages
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        if first.count <= maxTitleLength { return first }
        return String(first.prefix(maxTitleLength - 1)) + "…"
    }

    /// Normalize model output into a single clean title line.
    static func sanitize(_ raw: String) -> String? {
        // Drop model reasoning wrappers before taking a title line.
        var text = ThinkingExtractor.plainVisibleText(from: raw)
        guard !text.isEmpty else { return nil }

        // First line only — models sometimes add a second explanation line.
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip common wrapping quotes / markdown emphasis.
        let wrappers: [Character] = ["\"", "'", "`", "*", "“", "”", "‘", "’"]
        while let first = text.first, let last = text.last,
              wrappers.contains(first), wrappers.contains(last),
              text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Drop trailing period when the whole title is a short phrase.
        if text.hasSuffix("."), text.count <= 40, !text.dropLast().contains(".") {
            text = String(text.dropLast())
        }

        guard !text.isEmpty else { return nil }
        if text.count <= maxTitleLength { return text }
        return String(text.prefix(maxTitleLength - 1)) + "…"
    }

    // MARK: - Foundation Models

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func generateWithFoundationModel(
        firstUser: String,
        moreUsers: [String],
        assistants: [String]
    ) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }

        let instructions = """
        You name chat conversations for a coding assistant app.
        Reply with ONLY a short title: 2 to 6 words.
        No quotes, no trailing punctuation, no emoji, no explanation.
        Capture the topic; prefer nouns over full sentences.
        """

        var body = "User: \(clip(firstUser, limit: 500))"
        for msg in moreUsers {
            body += "\nUser: \(clip(msg, limit: 200))"
        }
        for msg in assistants {
            body += "\nAssistant: \(clip(msg, limit: 200))"
        }
        body += "\n\nTitle:"

        do {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(
                sampling: .greedy,
                temperature: 0.2,
                maximumResponseTokens: 24
            )
            let response = try await session.respond(to: body, options: options)
            return sanitize(response.content)
        } catch {
            return nil
        }
    }
    #endif

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
