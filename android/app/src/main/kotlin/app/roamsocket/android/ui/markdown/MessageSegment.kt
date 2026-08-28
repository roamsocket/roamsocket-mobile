package app.roamsocket.android.ui.markdown

/**
 * One renderable chunk of an assistant message body.
 *
 * Mirrors the iOS `MessageSegment` used by `MarkdownContentView`:
 *  - `MarkdownBody` is regular prose (rendered via Markwon).
 *  - `SnippetBlock` is a fenced `markdown` / `md` / `mdx` / `gfm` /
 *    `html` / `htm` / `xhtml` block that should stay raw with a Preview
 *    button.
 *  - `CodeBlock` is any other fenced code block (e.g. ```` ```python ````)
 *    lifted out of the prose so the UI can render it as its own card with
 *    a header (language label + Copy) and a syntax-highlighted body.
 *    The language string follows highlight.js conventions (already
 *    resolved from the fence info string by [MessageSegmentParser]).
 */
sealed class MessageSegment {
    data class MarkdownBody(val text: String) : MessageSegment()
    data class SnippetBlock(
        val kind: SnippetKind,
        val language: String,
        val code: String,
    ) : MessageSegment()
    data class CodeBlock(
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
 *  - every other fenced code block (e.g. `python`, `swift`, `ts`) becomes
 *    a [MessageSegment.CodeBlock] so the UI can render it with a header +
 *    Copy button + syntax-highlighted body;
 *  - a single leading/trailing newline around the fence body is stripped
 *    (the first character the user typed is usually a blank line).
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
                // Lift non-markdown / non-html fences into a code block with
                // a header + Copy + PrismJS highlighting. The label uses the
                // normalised highlight.js id when one is known, otherwise
                // we keep the raw info string so the user can still see it.
                val label = if (lang.isEmpty()) {
                    detectLanguage(trimmedCode) ?: "text"
                } else {
                    normaliseLanguage(lang) ?: lang
                }
                segments += MessageSegment.CodeBlock(
                    language = label,
                    code = trimmedCode,
                )
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

    /**
     * Map a fence info string to a PrismJS / highlight.js language id.
     * Returns null when the input is not a known alias — in that case the
     * caller should either fall back to the raw string (so the user sees
     * the label they wrote) or attempt auto-detection.
     */
    fun normaliseLanguage(raw: String): String? {
        val key = raw.trim().lowercase()
        if (key.isEmpty()) return null
        return LANGUAGE_ALIASES[key]
    }

    /**
     * Heuristic language detection when the fence info string is empty.
     * Inspects the first few non-empty lines for shebangs / package
     * declarations. Returns null when nothing obvious matches so the UI
     * falls back to a plain monospaced body.
     */
    fun detectLanguage(code: String): String? {
        val head = code.lineSequence()
            .filter { it.isNotBlank() }
            .take(4)
        for (line in head) {
            val lower = line.lowercase()
            if (lower.startsWith("#!")) {
                if ("python" in lower) return "python"
                if ("ruby" in lower) return "ruby"
                if ("bash" in lower || "/sh" in lower) return "bash"
                if ("node" in lower) return "javascript"
                if ("deno" in lower) return "typescript"
            }
            if (lower.startsWith("<?php")) return "php"
            if (lower.startsWith("package ") && ";" in lower) return "go"
            if (lower.startsWith("import ") && "\"" in lower && "from " !in lower) return "go"
        }
        return null
    }

    private val LANGUAGE_ALIASES: Map<String, String> = mapOf(
        // TypeScript / JavaScript family
        "ts" to "typescript", "tsx" to "typescript", "mts" to "typescript", "cts" to "typescript",
        "js" to "javascript", "jsx" to "javascript", "mjs" to "javascript", "cjs" to "javascript",
        // Common languages
        "py" to "python", "python" to "python",
        "rb" to "ruby", "ruby" to "ruby",
        "kt" to "kotlin", "kts" to "kotlin", "kotlin" to "kotlin",
        "sh" to "bash", "bash" to "bash", "zsh" to "bash", "shell" to "bash", "console" to "bash",
        "yml" to "yaml", "yaml" to "yaml",
        "cs" to "csharp", "csharp" to "csharp",
        "objc" to "objectivec", "objectivec" to "objectivec",
        "cpp" to "cpp", "c++" to "cpp", "cxx" to "cpp", "hpp" to "cpp", "hxx" to "cpp",
        "c" to "c", "h" to "c",
        "md" to "markdown", "mdx" to "markdown", "gfm" to "markdown", "markdown" to "markdown",
        "json" to "json", "json5" to "json",
        "vue" to "xml", "svelte" to "xml",
        "dockerfile" to "dockerfile", "docker" to "dockerfile",
        "r" to "r", "rs" to "rust", "rust" to "rust",
        "pl" to "perl", "perl" to "perl",
        "ex" to "elixir", "exs" to "elixir", "elixir" to "elixir",
        "lua" to "lua",
        "dart" to "dart",
        "scala" to "scala", "sc" to "scala",
        "hs" to "haskell", "haskell" to "haskell",
        "makefile" to "makefile", "mk" to "makefile", "make" to "makefile",
        "diff" to "diff", "patch" to "diff",
        "sql" to "sql",
        "graphql" to "graphql", "gql" to "graphql",
        "proto" to "protobuf", "protobuf" to "protobuf",
        "php" to "php",
        "ini" to "ini", "toml" to "ini", "cfg" to "ini",
        "log" to "plaintext", "txt" to "plaintext", "text" to "plaintext", "plain" to "plaintext",
        "xml" to "xml", "plist" to "xml", "html" to "xml", "htm" to "xml", "xhtml" to "xml",
    )
}
