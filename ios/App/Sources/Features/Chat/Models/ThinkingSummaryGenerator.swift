import Foundation

/// Short one-line labels for collapsed thinking rows. Uses **Lightweight Tasks**
/// (Apple Intelligence or a linked model); falls back to a truncated first sentence.
enum ThinkingSummaryGenerator {
    static let maxSummaryLength = 56

    static var isOnDeviceAvailable: Bool {
        LightweightTaskRunner.appleFoundationAvailable
    }

    static func summarize(_ thinking: String) async -> String {
        let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Thinking…" }

        let system = """
        You write a one-line label for a collapsed “thinking” row in a chat app.
        Reply with ONLY a short phrase (about 4 to 12 words).
        Past tense or progressive, e.g. “Weighed clarifying questions against…”.
        No quotes, no emoji, no full sentences with a period at the end.
        """
        let user = """
        Thinking:
        \(clip(trimmed, limit: 1_200))

        Label:
        """

        if let generated = await LightweightTaskRunner.complete(
            system: system,
            user: user,
            maxTokens: 32
        ), let clean = sanitize(generated) {
            return clean
        }

        return heuristicSummary(from: trimmed)
    }

    static func heuristicSummary(from thinking: String) -> String {
        var text = thinking
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Thinking…" }

        if let end = text.firstIndex(where: { ".!?\n".contains($0) }) {
            let sentence = text[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count >= 12 {
                text = sentence
            }
        }

        if text.count <= maxSummaryLength { return text }
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

        while let last = text.last, ".!?,;:".contains(last) {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { return nil }
        if text.count <= maxSummaryLength { return text }
        return heuristicSummary(from: text)
    }

    private static func clip(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…"
    }
}
