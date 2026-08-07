import Foundation

/// Names artifacts via **Lightweight Tasks** (Apple Intelligence or a
/// user-linked model). Falls back to the first useful content line.
enum ArtifactTitleGenerator {
    static let maxTitleLength = 64

    static var isOnDeviceAvailable: Bool {
        LightweightTaskRunner.appleFoundationAvailable
    }

    static func suggestTitle(for content: String) async -> String {
        let heuristic = heuristicTitle(from: content)
        let sample = clip(content, limit: 2_400)
        guard !sample.isEmpty else { return heuristic }

        let system = """
        You name saved chat artifacts (documents, code, reports) for a coding assistant app.
        Reply with ONLY a short title: 3 to 8 words.
        No quotes, no trailing punctuation, no emoji, no explanation, no markdown.
        Capture what the artifact is (e.g. "Instagram audio research notes", "Login form SwiftUI").
        Prefer concrete nouns over vague words like "document" or "response".
        """

        let user = """
        Artifact content:
        \(sample)

        Title:
        """

        if let generated = await LightweightTaskRunner.complete(
            system: system,
            user: user,
            maxTokens: 28
        ), let clean = sanitize(generated) {
            return clean
        }

        return heuristic
    }

    static func heuristicTitle(from content: String) -> String {
        let fence = content.range(of: #"```(\w+)?"#, options: .regularExpression)
        if let fence {
            // `lineRange(for:)` is non-optional — do not bind with `if let`.
            let lineRange = content.lineRange(for: fence.lowerBound..<fence.lowerBound)
            let fenceLine = content[lineRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if fenceLine.hasPrefix("```") {
                let lang = fenceLine.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                let after = content[lineRange.upperBound...]
                for raw in after.split(separator: "\n", omittingEmptySubsequences: true).prefix(3) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("```") { break }
                    if !line.isEmpty {
                        let snippet = String(line.prefix(40))
                        if lang.isEmpty { return sanitizeHeuristic(snippet) }
                        return sanitizeHeuristic("\(lang): \(snippet)")
                    }
                }
                if !lang.isEmpty { return sanitizeHeuristic("\(lang) code") }
            }
        }

        for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            if line.hasPrefix("#") {
                line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            }
            if !line.isEmpty {
                return sanitizeHeuristic(String(line.prefix(maxTitleLength)))
            }
        }
        return "Artifact"
    }

    static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("<think>") {
            if let end = text.range(of: "</think>", options: .caseInsensitive) {
                text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
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

        for prefix in ["Title:", "Name:", "Artifact:"] {
            if text.lowercased().hasPrefix(prefix.lowercased()) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if text.hasSuffix("."), text.count <= 48, !text.dropLast().contains(".") {
            text = String(text.dropLast())
        }

        guard !text.isEmpty else { return nil }
        if text.count <= maxTitleLength { return text }
        return String(text.prefix(maxTitleLength - 1)) + "…"
    }

    private static func sanitizeHeuristic(_ text: String) -> String {
        sanitize(text) ?? "Artifact"
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
