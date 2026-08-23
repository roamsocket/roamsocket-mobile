package app.roamsocket.android.ui.chat

/**
 * PR #79: a single `<memory ... />` tag parsed from an assistant
 * message. The model emits these inline in its reply when it
 * identifies a *stable* personal fact worth persisting; the client
 * strips the tags from the visible reply and applies the mutation
 * to the local memory store.
 *
 * Mirrors the iOS `memoryAutoSavePrompt` block at
 * `ios/.../ChatViewModel.swift:129-146`:
 *
 *  ```
 *  <memory action="add" category="you|topic|area" title="Profile" summary="…" details="…" />
 *  <memory action="forget" target="Verizon" />
 *  <memory action="rename" target="Profile" value="About me" />
 *  <memory action="set_summary" target="Profile" value="…" />
 *  <memory action="set_details" target="Profile" value="A|B|C" />
 *  ```
 *
 * Self-closing tags only — opening + closing `<memory>...</memory>`
 * forms are not produced by the model and are treated as no-ops.
 */
sealed interface MemoryTag {
    val target: String

    data class Add(
        val title: String,
        val summary: String,
        val details: String,
        val category: String,
    ) : MemoryTag {
        override val target: String get() = title
    }

    data class Update(
        override val target: String,
        val summary: String,
        val details: String,
    ) : MemoryTag

    data class Forget(
        override val target: String,
    ) : MemoryTag

    data class Rename(
        override val target: String,
        val value: String,
    ) : MemoryTag

    data class SetSummary(
        override val target: String,
        val value: String,
    ) : MemoryTag

    data class SetDetails(
        override val target: String,
        val value: String,
    ) : MemoryTag
}

/**
 * PR #79: extract `<memory ... />` tags from an assistant message
 * and return the parsed mutations. Tolerant of extra whitespace and
 * quote styles (single or double). Returns an empty list if the
 * reply doesn't carry any memory hints.
 *
 * Mirrors iOS `MemoryTagParser.swift` regex flavor; the Kotlin
 * version is intentionally strict on the *action* attribute and
 * permissive on the rest so a slightly-malformed tag is dropped
 * rather than corrupting the store.
 */
object MemoryTagParser {

    /**
     * Match a self-closing `<memory ... />` tag with arbitrary
     * attribute order. Captures the entire body so the per-attribute
     * scanner below can split it without re-regexing.
     */
    private val TAG_REGEX = Regex(
        """<memory\b([^>]*?)/>""",
        RegexOption.IGNORE_CASE,
    )

    fun parse(reply: String): List<MemoryTag> {
        if (reply.isEmpty()) return emptyList()
        return TAG_REGEX.findAll(reply).mapNotNull { match ->
            parseAttributes(match.groupValues[1])
        }.toList()
    }

    private fun parseAttributes(body: String): MemoryTag? {
        val attrs = parseAttrs(body)
        val action = attrs["action"]?.lowercase() ?: return null
        return when (action) {
            "add" -> MemoryTag.Add(
                title = attrs["title"].orEmpty().ifBlank { return null },
                summary = attrs["summary"].orEmpty(),
                details = attrs["details"].orEmpty(),
                category = attrs["category"].orEmpty(),
            )
            "update" -> {
                val target = attrs["target"].orEmpty().ifBlank { return null }
                MemoryTag.Update(
                    target = target,
                    summary = attrs["summary"].orEmpty(),
                    details = attrs["details"].orEmpty(),
                )
            }
            "forget" -> {
                val target = attrs["target"].orEmpty().ifBlank { return null }
                MemoryTag.Forget(target = target)
            }
            "rename" -> {
                val target = attrs["target"].orEmpty().ifBlank { return null }
                val value = attrs["value"].orEmpty().ifBlank { return null }
                MemoryTag.Rename(target = target, value = value)
            }
            "set_summary" -> {
                val target = attrs["target"].orEmpty().ifBlank { return null }
                val value = attrs["value"].orEmpty().ifBlank { return null }
                MemoryTag.SetSummary(target = target, value = value)
            }
            "set_details" -> {
                val target = attrs["target"].orEmpty().ifBlank { return null }
                val value = attrs["value"].orEmpty().ifBlank { return null }
                MemoryTag.SetDetails(target = target, value = value)
            }
            else -> null
        }
    }

    /**
     * Per-attribute regex. Matches `key="value"` or `key='value'`
     * with optional whitespace around the `=`. Captures the key in
     * group 1 and the unquoted value in group 2 (or 3 for single
     * quotes). Lets us tolerate multi-word values like
     * `summary="Lives in Colorado"` that the whitespace-split
     * approach would mangle.
     */
    private val ATTR_REGEX = Regex(
        """(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)')""",
    )

    /**
     * Mini-attribute parser: scan the tag body with [ATTR_REGEX] so
     * quoted values can contain spaces. The model emits double-quoted
     * values; the single-quote branch is for completeness. Deliberately
     * does not handle XML entities — the tags the model emits don't
     * carry any.
     */
    private fun parseAttrs(body: String): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (match in ATTR_REGEX.findAll(body)) {
            val key = match.groupValues[1].lowercase()
            val value = match.groupValues[2].ifEmpty { match.groupValues[3] }
            out[key] = value
        }
        return out
    }

    /**
     * Strip every `<memory ... />` tag from the visible reply so the
     * user only sees the natural-language response. Mirrors
     * iOS `MemoryTagParser.stripTags(reply)`.
     */
    fun stripTags(reply: String): String =
        TAG_REGEX.replace(reply, "").trim()
}
