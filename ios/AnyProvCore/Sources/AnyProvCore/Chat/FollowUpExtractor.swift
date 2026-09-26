import Foundation

/// Pulls a follow-up-suggestion list out of an assistant message so
/// the chat surface can render it as tappable chips below the
/// reply instead of as plain text.
///
/// Wire format (single line, anywhere in the message):
///
///     [SUGGEST: shorter follow-up | a different angle | a code example]
///
/// The brackets + `SUGGEST:` keyword keep it visually distinct from
/// regular text and trivial for any model to emit. We strip the
/// marker from the visible content so the user only sees the chips
/// (or the chips + the cleaned prose if other text surrounds the
/// marker).
///
/// Multiple lines are allowed (one per line). Empty entries and
/// surrounding whitespace are dropped. The case-insensitive
/// `SUGGEST:` keyword mirrors how we handle `<think>` tags.
public enum FollowUpExtractor {
    public struct Result: Equatable {
        /// Visible text with every suggestion marker removed (trimmed).
        public var content: String
        /// Ordered list of suggestion labels.
        public var suggestions: [String]
        /// True if at least one marker was present (used to short-circuit
        /// extraction on the hot path).
        public var hasSuggestions: Bool { !suggestions.isEmpty }
    }

    /// `[SUGGEST: a | b | c]` — at most ~200 chars per label so a runaway
    /// model doesn't fill the chip row.
    private static let pattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\[SUGGEST:\s*([^\]\n]{1,400})\]"#,
            options: [.caseInsensitive]
        )
    }()

    /// Suggested maximum per chip to keep the row tappable on
    /// iPhone. Anything longer gets truncated with an ellipsis.
    public static let maxLabelLength = 90

    public static func extract(from raw: String) -> Result {
        guard !raw.isEmpty else {
            return Result(content: raw, suggestions: [])
        }
        let nsRaw = raw as NSString
        let matches = pattern.matches(
            in: raw,
            options: [],
            range: NSRange(location: 0, length: nsRaw.length)
        )
        if matches.isEmpty {
            return Result(content: raw.trimmingCharacters(in: .whitespacesAndNewlines), suggestions: [])
        }
        // First pass: collect every match's labels in source order.
        var suggestions: [String] = []
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let body = nsRaw.substring(with: match.range(at: 1))
            for raw in body.components(separatedBy: "|") {
                let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                let capped = label.count > maxLabelLength
                    ? String(label.prefix(maxLabelLength - 1)) + "…"
                    : label
                suggestions.append(capped)
            }
        }
        // Second pass: strip the markers from the visible content.
        // Walk in reverse so each strip doesn't invalidate the
        // ranges that come after it.
        var stripped = raw
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let markerRange = match.range(at: 0)
            let nsStripped = stripped as NSString
            stripped = nsStripped.replacingCharacters(in: markerRange, with: "")
        }
        return Result(
            content: stripped.trimmingCharacters(in: .whitespacesAndNewlines),
            suggestions: suggestions
        )
    }
}
