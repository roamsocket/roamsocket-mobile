package app.roamsocket.android.ui.markdown

/**
 * One renderable chunk of an assistant message body.
 *
 * Mirrors the iOS `MessageSegment` used by `MarkdownContentView`:
 *  - `MarkdownBody` is regular prose (rendered via Markwon).
 *  - `SnippetBlock` is a fenced `markdown` / `md` / `mdx` / `gfm` /
 *    `html` / `htm` / `xhtml` block that should stay raw with a Preview
 *    button. Other language fences (e.g. `python`) fall through into
 *    the surrounding `MarkdownBody` and render as syntax-styled code
 *    blocks.
 */
sealed class MessageSegment {
    data class MarkdownBody(val text: String) : MessageSegment()
    data class SnippetBlock(
        val kind: SnippetKind,
        val language: String,
        val code: String,
    ) : MessageSegment()
}

/**
 * Mirror of the iOS `SnippetKind` raw values. The on-the-wire language
 * aliases (`md`, `mdx`, `gfm`, `htm`, `xhtml`) are resolved by
 * [MessageSegmentParser] before the segment is emitted.
 */
enum class SnippetKind {
    MARKDOWN,
    HTML,
}

/**
 * Splits a raw assistant message into renderable segments. Behaviour
 * matches the iOS `MessageSegmentParser`:
 *  - always returns at least one segment (the whole input as
 *    [MessageSegment.MarkdownBody] if no fences match);
 *  - only fenced blocks whose trimmed lowercase info string is one of
 *    the recognised snippet languages become [MessageSegment.SnippetBlock];
 *  - other language fences (e.g. `python`) are kept verbatim inside
 *    the surrounding markdown so Markwon can syntax-style them;
 *  - a single trailing newline after the fence open is stripped (the
 *    first character the user typed is usually a blank line).
 */
object MessageSegmentParser {
    // Captures: (1) the info string right after ``` and (2) the body up
    // to the closing ```. We deliberately forbid backticks and newlines
    // in the info string so we don't greedily consume a nested fence.
    private val FENCE_REGEX = Regex(
        pattern = "```([^\\n`]*)\\n([\\s\\S]*?)```",
    )

    fun parse(raw: String): List<MessageSegment> {
        if (raw.isEmpty()) return emptyList()

        val segments = mutableListOf<MessageSegment>()
        var cursor = 0

        for (match in FENCE_REGEX.findAll(raw)) {
            val whole = match.range
            val langRange = match.groups[1]!!.range
            val bodyRange = match.groups[2]!!.range

            if (whole.first > cursor) {
                val prose = raw.substring(cursor, whole.first)
                if (prose.isNotEmpty()) {
                    segments += MessageSegment.MarkdownBody(prose)
                }
            }

            val lang = raw.substring(langRange)
                .trim()
                .lowercase()
            var code = raw.substring(bodyRange)
            // Drop a single leading newline common immediately after the
            // fence open (the user usually starts on the next line).
            if (code.startsWith("\n")) code = code.drop(1)
            // Drop a single trailing newline common before the fence close.
            if (code.endsWith("\n")) code = code.dropLast(1)
            val trimmedCode = code

            val kind = snippetKindFor(lang)
            if (kind != null) {
                val label = if (lang.isEmpty()) kind.name.lowercase() else lang
                segments += MessageSegment.SnippetBlock(
                    kind = kind,
                    language = label,
                    code = trimmedCode,
                )
            } else {
                // Keep ordinary fences verbatim in the surrounding
                // markdown so Markwon renders them as code blocks.
                val fence = raw.substring(whole.first, whole.last + 1)
                segments += MessageSegment.MarkdownBody(fence)
            }

            cursor = whole.last + 1
        }

        if (cursor < raw.length) {
            val tail = raw.substring(cursor)
            if (tail.isNotEmpty()) {
                segments += MessageSegment.MarkdownBody(tail)
            }
        }

        return segments.ifEmpty { listOf(MessageSegment.MarkdownBody(raw)) }
    }

    private fun snippetKindFor(language: String): SnippetKind? = when (language) {
        "markdown", "md", "mdx", "gfm" -> SnippetKind.MARKDOWN
        "html", "htm", "xhtml" -> SnippetKind.HTML
        else -> null
    }
}
