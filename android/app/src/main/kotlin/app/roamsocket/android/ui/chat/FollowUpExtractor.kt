package app.roamsocket.android.ui.chat

/**
 * Pure-Kotlin port of the iOS `FollowUpExtractor`
 * (`ios/AnyProvCore/Sources/AnyProvCore/Chat/FollowUpExtractor.swift`).
 *
 * Pulls follow-up suggestion lists out of an assistant message so the
 * chat surface can render them as tappable chips below the reply
 * instead of as plain text. Mirrors the iOS contract 1:1 — same wire
 * formats, same chip caps, same code-fence behaviour. The shared
 * parity fixture in `docs/parity/follow-up-cases.json` exercises
 * both sides with the exact same input/output pairs.
 *
 * ## Wire formats supported
 *
 * 1. Bracket form (the canonical one we instruct the model to emit):
 *
 *     ```
 *     [SUGGEST: shorter follow-up | a different angle | a code example]
 *     ```
 *
 * 2. Angle-bracket form, used by some fine-tunes that learn XML
 *    tool-call conventions from each other:
 *
 *     ```
 *     <suggest>shorter follow-up</suggest>
 *     <suggest>a different angle</suggest>
 *     ```
 *
 * 3. Numbered list form, used by models that prefer a markdown list
 *    over a custom marker:
 *
 *     ```
 *     Next steps:
 *     1. Try the smaller API
 *     2. Add retry logic
 *     3. Switch to streaming
 *     ```
 *
 *    The numbered list detector only fires when (a) at least two
 *    consecutive lines match the `^\d+[.)]\s+\S` pattern and (b) the
 *    lines appear after a heading line that mentions a follow-up
 *    keyword ("next", "follow", "you can", "you might", "try",
 *    "consider", "want to", "explore").
 */
object FollowUpExtractor {

    /** Suggested max length for a single chip label. */
    const val MAX_LABEL_LENGTH = 90

    /** Cap on the total number of chips rendered. */
    const val MAX_SUGGESTIONS = 8

    data class Result(
        /** Visible text with every suggestion marker removed (trimmed). */
        val content: String,
        /** Ordered list of suggestion labels. */
        val suggestions: List<String>,
    ) {
        val hasSuggestions: Boolean get() = suggestions.isNotEmpty()
    }

    // Bracket form: [SUGGEST: a | b | c]. Up to 400 chars between
    // brackets and at most one bracket pair per line.
    private val BRACKET_PATTERN: Regex =
        Regex("""\[SUGGEST:\s*([^\]\n]{1,400})]""", RegexOption.IGNORE_CASE)

    // Angle-bracket form: <suggest>label</suggest>. Each label is its
    // own block; we don't allow nested tags.
    private val ANGLE_PATTERN: Regex =
        Regex("""<suggest\b[^>]*>([\s\S]{1,400}?)</suggest>""", RegexOption.IGNORE_CASE)

    // "Next steps"-style heading. Anchored to a word boundary so
    // "questionnaire" doesn't trip "next", and matched at the end of
    // the line so a sentence like "you can also check the docs"
    // doesn't trigger the heuristic.
    private val FOLLOW_UP_HEADING_PATTERN: Regex = Regex(
        """(?im)^[\s*#>\-]*(?:next\s+steps?|follow[\s\-]?ups?|you\s+can(?:\s+also)?|you\s+might(?:\s+want(?:\s+to)?)?|things?\s+to\s+try|to\s+explore|consider(?:\s+trying)?|want\s+to(?:\s+\w+){0,3}?)\s*[:.?!…\-\*]*\s*$"""
    )

    // Numbered list item. 1. or 1) style with at least one non-space
    // char of label.
    private val NUMBERED_ITEM_PATTERN: Regex =
        Regex("""^\s*\d{1,2}[.)]\s+(\S.{0,300})""")

    // Triple-backtick fenced code block. Used to skip the marker
    // inside code fences (so a literal [SUGGEST: …] example in a
    // code block isn't extracted as a chip or stripped from the
    // visible content).
    private val FENCED_CODE_BLOCK_PATTERN: Regex =
        Regex("""```[^\n]*\n[\s\S]*?```""")

    fun extract(raw: String): Result {
        if (raw.isEmpty()) return Result(content = raw, suggestions = emptyList())

        // Mask the body of every fenced code block with whitespace of
        // the same length. Markers found in `masked` map 1:1 to
        // positions in `raw` so we run the strip pass on `raw` to
        // keep the code-fence content intact.
        val masked = maskCodeFences(raw)

        val collected = mutableListOf<String>()
        var visible = raw

        // 1. Bracket form.
        val bracketMatches = BRACKET_PATTERN.findAll(masked).toList()
        if (bracketMatches.isNotEmpty()) {
            // First pass: collect labels in source order.
            for (match in bracketMatches) {
                val body = match.groupValues[1]
                for (rawLabel in body.split('|')) {
                    val label = rawLabel.trim()
                    if (label.isNotEmpty()) {
                        collected.add(capped(label))
                    }
                }
            }
            // Second pass: strip markers walking in reverse so each
            // strip doesn't invalidate the ranges that follow.
            for (match in bracketMatches.reversed()) {
                visible = visible.replaceRange(match.range.first..<match.range.last + 1, "")
            }
        }

        // 2. Angle-bracket form.
        val angleMatches = ANGLE_PATTERN.findAll(masked).toList()
        if (angleMatches.isNotEmpty()) {
            for (match in angleMatches) {
                val body = match.groupValues[1].trim()
                if (body.isNotEmpty()) {
                    collected.add(capped(body))
                }
            }
            for (match in angleMatches.reversed()) {
                visible = visible.replaceRange(match.range.first..<match.range.last + 1, "")
            }
        }

        // 3. Numbered list form (only if we haven't already collected
        //    a richer marker — bracket/angle chips are more specific).
        if (collected.isEmpty()) {
            val numbered = numberedFollowUps(masked)
            if (numbered != null) {
                collected.addAll(numbered.labels)
                // Strip the heading + the numbered list, in reverse so
                // ranges stay valid.
                val allRanges = (numbered.lineRanges + listOfNotNull(numbered.headingRange))
                    .sortedByDescending { it.first }
                for (range in allRanges) {
                    visible = visible.replaceRange(range.first..<range.last + 1, "")
                }
            }
        }

        // De-dupe while preserving order, then cap. A model that
        // emits both a bracket and a numbered list pointing at the
        // same three options shouldn't render six chips.
        val seen = mutableSetOf<String>()
        val deduped = mutableListOf<String>()
        for (label in collected) {
            val key = label.lowercase()
            if (seen.add(key)) {
                deduped.add(label)
                if (deduped.size >= MAX_SUGGESTIONS) break
            }
        }

        return Result(
            content = visible.trim(),
            suggestions = deduped,
        )
    }

    // MARK: - Helpers

    /** Truncate a single label to [MAX_LABEL_LENGTH] with an ellipsis. */
    private fun capped(label: String): String {
        if (label.length <= MAX_LABEL_LENGTH) return label
        return label.substring(0, MAX_LABEL_LENGTH - 1) + "…"
    }

    /**
     * Replace the body of every fenced code block with whitespace of
     * the same length, preserving the fence markers and line breaks
     * so character offsets stay aligned with `raw`. Mirrors the iOS
     * implementation exactly.
     */
    private fun maskCodeFences(raw: String): String {
        val matches = FENCED_CODE_BLOCK_PATTERN.findAll(raw).toList()
        if (matches.isEmpty()) return raw
        // Build by walking the string and replacing fence bodies with
        // whitespace. Indices in `raw` are stable because we keep the
        // fence opener and closer and only blank out the inner body.
        var out = raw
        for (match in matches.reversed()) {
            val body = match.value
            val firstNewline = body.indexOf('\n')
            if (firstNewline < 0) continue
            val openerPart = body.substring(0, firstNewline + 1)
            // Closing fence is the last 3 chars; keep them.
            val innerEnd = body.length - 3
            val inner = body.substring(firstNewline + 1, innerEnd)
            val blanked = " ".repeat(inner.length)
            val replaced = openerPart + blanked + "```"
            out = out.replaceRange(match.range.first..<match.range.last + 1, replaced)
        }
        return out
    }

    /**
     * Try to detect a numbered-list follow-up section in the
     * (possibly code-fence-masked) `raw` input. Returns the labels,
     * the per-line ranges to strip, and the heading range to strip.
     */
    private fun numberedFollowUps(raw: String): NumberedFollowUps? {
        val headingMatch = FOLLOW_UP_HEADING_PATTERN.find(raw) ?: return null
        val headingRange = headingMatch.range
        val lines = raw.split('\n')
        val headingLineEnd = headingRange.last + 1

        // Find the line index of the heading.
        var charPos = 0
        var headingIndex = -1
        for ((i, line) in lines.withIndex()) {
            val lineLen = line.length
            if (charPos + lineLen >= headingLineEnd) {
                headingIndex = i
                break
            }
            charPos += lineLen + 1 // +1 for the \n
        }
        if (headingIndex < 0) return null

        val labels = mutableListOf<String>()
        val lineRanges = mutableListOf<IntRange>()
        var offset = 0
        for ((i, line) in lines.withIndex()) {
            // Defer-style: do the increment at the end of the
            // iteration so `offset` is the start of line i when we
            // record the range.
            val deferOffset = offset
            offset += line.length + 1
            if (i < headingIndex + 1) continue
            if (line.isBlank()) continue
            val match = NUMBERED_ITEM_PATTERN.find(line) ?: break
            val label = match.groupValues[1].trim()
            if (label.isNotEmpty()) {
                labels.add(capped(label))
                lineRanges.add(deferOffset..<deferOffset + line.length)
            }
            if (labels.size >= MAX_SUGGESTIONS) break
        }
        // Need at least 2 numbered items; otherwise we misfired.
        if (labels.size < 2) return null
        return NumberedFollowUps(labels, lineRanges, headingRange)
    }

    private data class NumberedFollowUps(
        val labels: List<String>,
        val lineRanges: List<IntRange>,
        val headingRange: IntRange?,
    )
}
