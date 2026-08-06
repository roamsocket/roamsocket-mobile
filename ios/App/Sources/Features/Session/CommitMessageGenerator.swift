import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Suggests a one-line git commit subject using Apple's on-device Foundation
/// Model when available (iOS 26+ / Apple Intelligence). Falls back to a
/// heuristic from the task / diff stats so commit still works offline and
/// on older OS versions — same approach as `ChatTitleGenerator`.
enum CommitMessageGenerator {
    static let maxSubjectLength = 72

    /// Whether the on-device Apple Intelligence model can run commit generation.
    static var isOnDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Prefer Foundation Models; otherwise return `fallback`.
    static func suggest(
        task: String,
        diffSummary: String,
        fallback: String
    ) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let generated = await generateWithFoundationModel(
                task: task,
                diffSummary: diffSummary
            ) {
                return generated
            }
        }
        #endif
        return fallback
    }

    /// Normalize model output into a single clean subject line.
    static func sanitize(_ raw: String) -> String? {
        // Drop reasoning wrappers if a model ever emits them.
        guard var text = ThinkingExtractor.firstPlainLine(from: raw) else { return nil }

        // Strip wrapping quotes / markdown emphasis.
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

    // MARK: - Foundation Models

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func generateWithFoundationModel(
        task: String,
        diffSummary: String
    ) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }

        let instructions = """
        You write git commit subject lines for a coding assistant app.
        Reply with ONLY a single subject line (max ~72 characters).
        Prefer conventional commits when it fits (feat:, fix:, refactor:, docs:, chore:, test:).
        No quotes, no body, no explanation, no emoji, no reasoning tags.
        """

        let body = """
        Task: \(clip(task, limit: 400))

        Diff summary:
        \(clip(diffSummary, limit: 2_500))

        Commit subject:
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(
                sampling: .greedy,
                temperature: 0.2,
                maximumResponseTokens: 40
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
