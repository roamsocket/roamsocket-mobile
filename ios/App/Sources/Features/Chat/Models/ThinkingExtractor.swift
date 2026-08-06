import Foundation

/// Pulls model reasoning out of assistant text that wraps it in
/// `<think>…</think>` (or `<thinking>…</thinking>`) tags so the UI can
/// show it as a collapsible block instead of raw markup.
enum ThinkingExtractor {
    struct Result: Equatable {
        /// Concatenated inner text of all thinking tags, or nil if none.
        var thinking: String?
        /// Original string with thinking tags removed (trimmed).
        var content: String
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

    static func extract(from raw: String) -> Result {
        guard !raw.isEmpty else {
            return Result(thinking: nil, content: raw)
        }

        let full = NSRange(raw.startIndex..., in: raw)
        var thinkingParts: [String] = []
        var stripped: String

        let matches = pairedPattern.matches(in: raw, options: [], range: full)
        if !matches.isEmpty {
            thinkingParts = matches.compactMap { match in
                guard match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: raw) else { return nil }
                let part = String(raw[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                return part.isEmpty ? nil : part
            }
            stripped = pairedPattern.stringByReplacingMatches(
                in: raw,
                options: [],
                range: full,
                withTemplate: ""
            )
        } else if let open = openOnlyPattern.firstMatch(in: raw, options: [], range: full),
                  open.numberOfRanges > 1,
                  let innerRange = Range(open.range(at: 1), in: raw),
                  let outerRange = Range(open.range, in: raw) {
            let part = String(raw[innerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { thinkingParts = [part] }
            stripped = String(raw[..<outerRange.lowerBound])
        } else {
            return Result(thinking: nil, content: raw)
        }

        let thinkingJoined = thinkingParts.joined(separator: "\n\n")
        let thinking: String? = thinkingJoined.isEmpty ? nil : thinkingJoined
        // Tag removal can leave doubled spaces / blank runs — tidy lightly.
        let content = stripped
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Result(thinking: thinking, content: content)
    }
}
