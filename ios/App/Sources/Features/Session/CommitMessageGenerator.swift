import Foundation

/// Suggests a one-line git commit subject via **Lightweight Tasks**
/// (Apple Intelligence or a linked model). Falls back to a heuristic.
enum CommitMessageGenerator {
    static let maxSubjectLength = 72

    static var isOnDeviceAvailable: Bool {
        LightweightTaskRunner.appleFoundationAvailable
    }

    static func suggest(
        task: String,
        diffSummary: String,
        fallback: String
    ) async -> String {
        let system = """
        You write git commit subject lines for a coding assistant app.
        Reply with ONLY a single subject line (max ~72 characters).
        Prefer conventional commits when it fits (feat:, fix:, refactor:, docs:, chore:, test:).
        No quotes, no body, no explanation, no emoji, no reasoning tags.
        """

        let user = """
        Task: \(clip(task, limit: 400))

        Diff summary:
        \(clip(diffSummary, limit: 2_500))

        Commit subject:
        """

        if let generated = await LightweightTaskRunner.complete(
            system: system,
            user: user,
            maxTokens: 40
        ), let clean = sanitize(generated) {
            return clean
        }
        return fallback
    }

    static func sanitize(_ raw: String) -> String? {
        guard var text = ThinkingExtractor.firstPlainLine(from: raw) else { return nil }

        let wrappers: [Character] = ["\"", "'", "`", "*", "“", "”", "‘", "’"]
        while let first = text.first, let last = text.last,
              wrappers.contains(first), wrappers.contains(last),
              text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { return nil }
        if text.count <= maxSubjectLength { return text }
        return String(text.prefix(maxSubjectLength))
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
