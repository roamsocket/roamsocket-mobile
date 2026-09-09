import Foundation

/// Pulls follow-up suggestion lists out of an assistant message so the
/// chat surface can render them as tappable chips below the reply
/// instead of as plain text.
///
/// ## Wire formats supported
///
/// All formats are case-insensitive and may appear anywhere in the
/// message. Multiple markers (even mixed formats) are merged in source
/// order; the first chip is the first suggestion, the last chip is the
/// last suggestion.
///
/// 1. Bracket form (the canonical one we instruct the model to emit):
///
///     ```
///     [SUGGEST: shorter follow-up | a different angle | a code example]
///     ```
///
///    `SUGGEST:` is the keyword; pipe `|` separates labels. Newlines
///    inside a single marker are not allowed (so a stray `]` always
///    closes the marker) but multiple marker lines are.
///
/// 2. Angle-bracket form, used by some fine-tunes that learn XML
///    tool-call conventions from each other:
///
///     ```
///     <suggest>shorter follow-up</suggest>
///     <suggest>a different angle</suggest>
///     ```
///
///    Labels in the angle-bracket form are each label's *own* marker
///    (one suggestion per `<suggest>…</suggest>` block), not pipe
///    separated.
///
/// 3. Numbered list form, used by models that prefer a markdown list
///    over a custom marker:
///
///     ```
///     Next steps:
///     1. Try the smaller API
///     2. Add retry logic
///     3. Switch to streaming
///     ```
///
///    The numbered list detector only fires when (a) at least two
///    consecutive lines match the `^\d+[.)]\s+\S` pattern and (b) the
///    lines appear after a heading line that mentions a follow-up
///    keyword ("next", "follow", "you can", "you might", "try",
///    "consider", "want to", "explore"). Otherwise a benign list in
///    the assistant's prose (e.g. "1. The cause … 2. The fix …") would
///    be misclassified as suggestions.
///
/// Every format strips its marker from the visible content. The chip
/// row is rendered by the view layer (`FollowUpChips`).
public enum FollowUpExtractor {

    /// Suggested max length for a single chip label, so a runaway
    /// model can't fill the chip row with a 2k-character wall of text.
    /// Anything longer is truncated with an ellipsis.
    public static let maxLabelLength = 90

    /// Cap on the total number of chips rendered. Catches pathological
    /// cases (a model emits 200 suggestions) so the chip row doesn't
    /// dominate the screen.
    public static let maxSuggestions = 8

    public struct Result: Equatable {
        /// Visible text with every suggestion marker removed (trimmed).
        public var content: String
        /// Ordered list of suggestion labels.
        public var suggestions: [String]
        /// True if at least one marker was present.
        public var hasSuggestions: Bool { !suggestions.isEmpty }
    }

    // MARK: - Regex patterns

    /// Bracket form: `[SUGGEST: a | b | c]`. Up to 400 chars between
    /// brackets (enough for ~4 reasonable labels) and at most one
    /// bracket pair per line so a stray `]` always closes the marker.
    /// The capture group is the inner labels.
    private static let bracketPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\[SUGGEST:\s*([^\]\n]{1,400})]"#,
            options: [.caseInsensitive]
        )
    }()

    /// Angle-bracket form: `<suggest>label</suggest>`. Each label is
    /// its own block; we don't allow nested tags so user text like
    /// `<suggest>use a <key>thing</key></suggest>` doesn't get
    /// half-eaten.
    private static let anglePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"<suggest\b[^>]*>([\s\S]{1,400}?)</suggest>"#,
            options: [.caseInsensitive]
        )
    }()

    /// "Next steps"-style heading. Anchored to a word boundary so
    /// "questionnaire" doesn't trip "next", and matched at the end
    /// of the line so a sentence like "you can also check the docs"
    /// doesn't trigger the heuristic.
    ///
    /// All alternations accept an optional trailing colon / question
    /// mark / period / ellipsis / closing markdown (so a heading
    /// rendered as `**Next steps:**` still matches as a whole line).
    private static let followUpHeadingPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?im)^[\s*#>\-]*(?:next\s+steps?|follow[\s\-]?ups?|you\s+can(?:\s+also)?|you\s+might(?:\s+want(?:\s+to)?)?|things?\s+to\s+try|to\s+explore|consider(?:\s+trying)?|want\s+to(?:\s+\w+){0,3}?)\s*[:.?!…\-\*]*\s*$"#,
            options: []
        )
    }()

    /// Numbered list item. `1.` or `1)` style with at least one
    /// non-space char of label.
    private static let numberedItemPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^\s*\d{1,2}[.)]\s+(\S.{0,300})"#,
            options: []
        )
    }()

    // MARK: - Public API

    /// Triple-backtick fenced code block. Captures the fence opener
    /// (e.g. "```swift") and the closer ("```") so we can find the
    /// character range of every fenced block and skip it during marker
    /// extraction. Inline single-backtick code spans are not handled
    /// (most models don't emit `[SUGGEST: ...]` inline; the bracket
    /// form is the one that matters here).
    private static let fencedCodeBlockPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "```[^\n]*\n[\\s\\S]*?```",
            options: []
        )
    }()

    public static func extract(from raw: String) -> Result {
        guard !raw.isEmpty else {
            return Result(content: raw, suggestions: [])
        }

        // Build a "search mask" that hides the contents of every
        // fenced code block. The model can legitimately emit a literal
        // `[SUGGEST: ...]` example inside a code fence, and we don't
        // want to either extract it as a chip or strip the line out
        // of the visible content. We do this by replacing the block
        // body with placeholder whitespace of the same length so
        // character ranges stay aligned with the original string —
        // markers found in `masked` apply to `raw` 1:1, so we run the
        // strip pass on `raw` to keep the code-fence content intact.
        let masked = maskCodeFences(in: raw)

        var collected: [String] = []
        var visible = raw

        // 1. Bracket form first so the marker removal doesn't disturb
        //    angle-bracket or numbered-list boundaries.
        let bracketMatches = bracketPattern.matches(
            in: masked,
            options: [],
            range: NSRange(location: 0, length: (masked as NSString).length)
        )
        if !bracketMatches.isEmpty {
            // First pass: collect labels in source order.
            for match in bracketMatches {
                let body = (masked as NSString).substring(with: match.range(at: 1))
                for raw in body.components(separatedBy: "|") {
                    let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !label.isEmpty {
                        collected.append(capped(label))
                    }
                }
            }
            // Second pass: strip markers walking in reverse so each
            // strip doesn't invalidate the ranges that follow.
            for match in bracketMatches.reversed() {
                let ns = visible as NSString
                visible = ns.replacingCharacters(in: match.range, with: "")
            }
        }

        // 2. Angle-bracket form. Same first-pass / reverse-strip
        //    discipline so the body of the last `<suggest>` doesn't
        //    leak across the next marker.
        let angleMatches = anglePattern.matches(
            in: masked,
            options: [],
            range: NSRange(location: 0, length: (masked as NSString).length)
        )
        if !angleMatches.isEmpty {
            for match in angleMatches {
                let body = (masked as NSString).substring(with: match.range(at: 1))
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    collected.append(capped(trimmed))
                }
            }
            for match in angleMatches.reversed() {
                let ns = visible as NSString
                visible = ns.replacingCharacters(in: match.range, with: "")
            }
        }

        // 3. Numbered list form (only if we haven't already collected
        //    a richer marker — bracket/angle chips are more specific).
        if collected.isEmpty {
            if let (labels, lineRanges, headingRange) = numberedFollowUps(in: masked) {
                collected.append(contentsOf: labels)
                // Strip the heading + the numbered list, in reverse so
                // ranges stay valid.
                let allRanges = (lineRanges + (headingRange.map { [$0] } ?? []))
                    .sorted(by: { $0.location > $1.location })
                for range in allRanges {
                    let ns = visible as NSString
                    visible = ns.replacingCharacters(in: range, with: "")
                }
            }
        }

        // De-dupe while preserving order, then cap. A model that emits
        // both a bracket and a numbered list pointing at the same
        // three options shouldn't render six chips.
        var seen = Set<String>()
        var deduped: [String] = []
        for label in collected {
            let key = label.lowercased()
            if seen.insert(key).inserted {
                deduped.append(label)
                if deduped.count >= maxSuggestions { break }
            }
        }

        return Result(
            content: visible.trimmingCharacters(in: .whitespacesAndNewlines),
            suggestions: deduped
        )
    }

    // MARK: - Helpers

    /// Replace the body of every fenced code block with whitespace
    /// (preserving the fence markers and line breaks so character
    /// offsets stay aligned with `raw`). The bracketed content
    /// disappears from regex scanning but stays in the final
    /// `Result.content` because we work on `masked` for *extraction*
    /// only — the visible-text return value is the un-masked string
    /// minus the markers we found.
    private static func maskCodeFences(in raw: String) -> String {
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = fencedCodeBlockPattern.matches(in: raw, options: [], range: full)
        guard !matches.isEmpty else { return raw }
        var out = raw as NSString
        for match in matches.reversed() {
            let body = ns.substring(with: match.range)
            // Keep the opener line (e.g. "```swift\n"), blank out the
            // body until just before the closing "```".
            guard let firstNewline = body.firstIndex(of: "\n") else { continue }
            let openerPart = String(body[body.startIndex...firstNewline])
            let bodyStart = body.index(after: firstNewline)
            // Closing fence is the last 3 chars; keep them.
            let innerEnd = body.index(body.endIndex, offsetBy: -3)
            let inner = String(body[bodyStart..<innerEnd])
            let blanked = String(repeating: " ", count: inner.count)
            let replaced = openerPart + blanked + "```"
            out = out.replacingCharacters(in: match.range, with: replaced) as NSString
        }
        return out as String
    }

    /// Truncate a single label to `maxLabelLength` characters with an
    /// ellipsis suffix.
    private static func capped(_ label: String) -> String {
        guard label.count > maxLabelLength else { return label }
        return String(label.prefix(maxLabelLength - 1)) + "…"
    }

    /// Try to detect a numbered-list follow-up section. Returns the
    /// labels (in source order), the per-line ranges, and the heading
    /// range to strip, all matching the (possibly code-fence-masked)
    /// `raw` input.
    private static func numberedFollowUps(in raw: String) -> (labels: [String], ranges: [NSRange], heading: NSRange?)? {
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Find the first heading that triggers the follow-up heuristic.
        guard let headingMatch = followUpHeadingPattern.firstMatch(in: raw, options: [], range: full) else {
            return nil
        }
        let headingRange = headingMatch.range
        // Convert the heading range into a line index by counting
        // newlines before it. We also need the line at that index
        // to compute the heading's start offset for the strip pass.
        let prefix = ns.substring(to: headingRange.location + headingRange.length)
        let headingLineEnd = headingRange.location + headingRange.length
        let lines = raw.components(separatedBy: .newlines)
        var charPos = 0
        var headingIndex: Int = -1
        for (i, line) in lines.enumerated() {
            let lineLen = (line as NSString).length
            if charPos + lineLen >= headingLineEnd {
                headingIndex = i
                break
            }
            charPos += lineLen + 1 // +1 for the separator
        }
        guard headingIndex >= 0 else { return nil }

        // From the line after the heading, take any consecutive
        // numbered items. Stop at the first non-numbered, non-blank
        // line so a 3-item follow-up block at the end of a longer
        // reply doesn't get truncated.
        var labels: [String] = []
        var lineRanges: [NSRange] = []
        // Track the character offset of the line we just consumed so
        // we can build a strippable range for each line.
        var offset = 0
        for (i, line) in lines.enumerated() {
            defer { offset += (line as NSString).length + 1 } // +1 for the \n
            if i < headingIndex + 1 { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let lineNS = line as NSString
            if let m = numberedItemPattern.firstMatch(
                in: line,
                options: [],
                range: NSRange(location: 0, length: lineNS.length)
            ) {
                let label = lineNS.substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty {
                    labels.append(capped(label))
                    lineRanges.append(NSRange(location: offset, length: lineNS.length))
                }
                if labels.count >= maxSuggestions { break }
            } else {
                break
            }
        }
        // Need at least 2 numbered items; otherwise we misfired (a
        // "1. The user requested X" inside prose would be a false
        // positive if we accepted a single hit).
        guard labels.count >= 2 else { return nil }
        return (labels, lineRanges, headingRange)
    }
}
