import Foundation

/// Pulls model reasoning out of assistant text that wraps it in
/// `<think>…</think>` (or `<thinking>…</thinking>`) tags so the UI can
/// show it as a collapsible block instead of raw markup.
enum ThinkingExtractor {
    struct Result: Equatable {
        /// Inner reasoning text. Non-nil when thinking tags were detected
        /// (empty string while streaming an open tag with no body yet).
        var thinking: String?
        /// Original string with thinking tags removed (trimmed).
        var content: String
        /// Open thinking tag has not been closed yet (streaming / incomplete).
        var isThinkingOpen: Bool
    }

    /// Paired tags; multi-line body. Case-insensitive tag name.
    private static let pairedPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"<think(?:ing)?>([\s\S]*?)</think(?:ing)?>"#,
            options: [.caseInsensitive]
        )
    }()

    /// Unclosed open tag (e.g. still streaming). Captures everything after it.
    private static let openOnlyPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"<think(?:ing)?>([\s\S]*)$"#,
            options: [.caseInsensitive]
        )
    }()

    /// Partial open tag at end of stream (`<thi`, `<think`, `<thinking ` …).
    private static let incompleteOpenPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"<think(?:ing)?\b[^>]*$"#,
            options: [.caseInsensitive]
        )
    }()

    /// Stray open/close tags left after primary extraction.
    private static let residualTagPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"</?think(?:ing)?>"#,
            options: [.caseInsensitive]
        )
    }()

    static func extract(from raw: String) -> Result {
        guard !raw.isEmpty else {
            return Result(thinking: nil, content: raw, isThinkingOpen: false)
        }

        var thinkingParts: [String] = []
        var stripped = raw
        var sawThinkingTags = false
        var isThinkingOpen = false

        let full = NSRange(stripped.startIndex..., in: stripped)
        let matches = pairedPattern.matches(in: stripped, options: [], range: full)
        if !matches.isEmpty {
            sawThinkingTags = true
            thinkingParts = matches.compactMap { match in
                guard match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: stripped) else { return nil }
                let part = String(stripped[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                return part.isEmpty ? nil : part
            }
            stripped = pairedPattern.stringByReplacingMatches(
                in: stripped,
                options: [],
                range: full,
                withTemplate: ""
            )
        }

        let afterPairs = NSRange(stripped.startIndex..., in: stripped)
        if let open = openOnlyPattern.firstMatch(in: stripped, options: [], range: afterPairs),
           open.numberOfRanges > 1,
           let innerRange = Range(open.range(at: 1), in: stripped),
           let outerRange = Range(open.range, in: stripped) {
            sawThinkingTags = true
            isThinkingOpen = true
            let part = String(stripped[innerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { thinkingParts.append(part) }
            stripped = String(stripped[..<outerRange.lowerBound])
        } else if let incomplete = incompleteOpenPattern.firstMatch(
            in: stripped, options: [], range: afterPairs
        ), let outerRange = Range(incomplete.range, in: stripped) {
            // Streaming mid-tag (`…\n<th` / `…<think`) — hide it and show Thinking…
            sawThinkingTags = true
            isThinkingOpen = true
            stripped = String(stripped[..<outerRange.lowerBound])
        }

        // Orphan close/open tags must never leak into the bubble.
        let residualRange = NSRange(stripped.startIndex..., in: stripped)
        if residualTagPattern.firstMatch(in: stripped, options: [], range: residualRange) != nil {
            sawThinkingTags = true
            stripped = residualTagPattern.stringByReplacingMatches(
                in: stripped,
                options: [],
                range: residualRange,
                withTemplate: ""
            )
        }

        let thinkingJoined = thinkingParts.joined(separator: "\n\n")
        // Non-nil whenever tags were present — empty body still means "thinking UI".
        let thinking: String? = sawThinkingTags ? thinkingJoined : nil

        let content = tidy(stripped)
        return Result(thinking: thinking, content: content, isThinkingOpen: isThinkingOpen)
    }

    /// Visible answer only — thinking markup removed. Use for commit subjects,
    /// titles, and any plain-text sink that must not see `<think>` tokens.
    static func plainVisibleText(from raw: String) -> String {
        extract(from: raw).content
    }

    /// First non-empty plain line after stripping thinking (and quotes).
    /// Returns nil when nothing usable remains.
    static func firstPlainLine(from raw: String) -> String? {
        let content = plainVisibleText(from: raw)
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !looksLikeThinkingMarkup($0) }
        guard var line = lines.first else { return nil }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !line.isEmpty, !looksLikeThinkingMarkup(line) else { return nil }
        return line
    }

    private static func looksLikeThinkingMarkup(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("<think")
            || lower.hasPrefix("</think")
            || lower == "<thinking>"
            || lower == "</thinking>"
    }

    private static func tidy(_ stripped: String) -> String {
        stripped
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
