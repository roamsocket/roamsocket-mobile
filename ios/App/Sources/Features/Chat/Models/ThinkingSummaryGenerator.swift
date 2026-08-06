import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Short one-line labels for collapsed thinking rows (Claude-style:
/// “Weighed clarifying questions against…”). Prefers Apple’s on-device
/// Foundation Model; falls back to a truncated first sentence.
enum ThinkingSummaryGenerator {
    static let maxSummaryLength = 56

    static var isOnDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Prefer Foundation Models; otherwise a heuristic clip of `thinking`.
    static func summarize(_ thinking: String) async -> String {
        let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Thinking…" }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let generated = await generateWithFoundationModel(thinking: trimmed) {
                return generated
            }
        }
        #endif

        return heuristicSummary(from: trimmed)
    }

    /// Instant label while the on-device model runs (or when unavailable).
    static func heuristicSummary(from thinking: String) -> String {
        var text = thinking
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Thinking…" }

        // Prefer first sentence-ish chunk.
        if let end = text.firstIndex(where: { ".!?\n".contains($0) }) {
            let sentence = text[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count >= 12 {
                text = sentence
            }
        }

        if text.count <= maxSummaryLength { return text }
        // Break on a word boundary when possible.
        let clipped = String(text.prefix(maxSummaryLength - 1))
        if let lastSpace = clipped.lastIndex(of: " "), lastSpace > clipped.startIndex {
            return String(clipped[..<lastSpace]) + "…"
        }
        return clipped + "…"
    }

    static func sanitize(_ raw: String) -> String? {
        var text = ThinkingExtractor.plainVisibleText(from: raw)
        if text.isEmpty {
            text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

        // Drop trailing sentence punctuation — Claude-style fragments.
        while let last = text.last, ".!?,;:".contains(last) {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { return nil }
        if text.count <= maxSummaryLength { return text }
        return heuristicSummary(from: text)
    }

    // MARK: - Foundation Models

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func generateWithFoundationModel(thinking: String) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }

        let instructions = """
        You write a one-line label for a collapsed “thinking” row in a chat app.
        Reply with ONLY a short phrase (about 4 to 12 words).
        Prefer past-tense or gerund style, like:
        - Weighed clarifying questions against building the outline first
        - Compared two approaches for the API design
        - Drafted a plan for the training outline
        No quotes, no trailing punctuation, no emoji, no explanation.
        """

        let body = """
        Reasoning:
        \(clip(thinking, limit: 1_800))

        Label:
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(
                sampling: .greedy,
                temperature: 0.2,
                maximumResponseTokens: 28
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
