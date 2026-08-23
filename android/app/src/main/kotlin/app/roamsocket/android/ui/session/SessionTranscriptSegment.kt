package app.roamsocket.android.ui.session

/**
 * One renderable chunk of the coding-session transcript. Either a single
 * non-tool item rendered as before, or a contiguous run of tool items
 * collapsed into one "action group" card.
 *
 * Mirrors `ios/.../SessionActionHistoryView.TranscriptSegment` from PR
 * #67. The iOS session transcript previously rendered one card per tool
 * call, which made the chat scroll quickly when the agent ran many
 * commands. Grouping keeps the inline transcript compact and pushes the
 * full list into a dedicated sheet.
 */
sealed interface SessionTranscriptSegment {
    /** A single non-tool row (user bubble, assistant text, diff, notice). */
    data class Item(val item: TranscriptItem) : SessionTranscriptSegment

    /**
     * One or more consecutive tool items collapsed into a single card.
     *
     * The [id] is anchored to the first tool's id so it stays stable as
     * the group grows and Compose can animate the change instead of
     * tearing down and rebuilding the row.
     */
    data class Actions(val id: String, val tools: List<TranscriptItem.Tool>) : SessionTranscriptSegment

    /**
     * Stable key for `LazyColumn` `key = { it.id }` calls. Both
     * variants expose a string so the screen doesn't need a separate
     * fallback.
     */
    val segmentId: String
        get() = when (this) {
            is Item -> item.key()
            is Actions -> id
        }
}

/**
 * Walk the live transcript and bucket consecutive `Tool` rows into a
 * single `Actions` segment. Non-tool items pass through as `Item`
 * segments in the same order. Preserves transcript order so the
 * surrounding user/assistant/diff/notice rows stay interleaved
 * correctly.
 */
internal fun sessionTranscriptSegments(
    items: List<TranscriptItem>,
): List<SessionTranscriptSegment> {
    val out = mutableListOf<SessionTranscriptSegment>()
    var pendingTools = mutableListOf<TranscriptItem.Tool>()
    for (item in items) {
        if (item is TranscriptItem.Tool) {
            pendingTools += item
        } else {
            if (pendingTools.isNotEmpty()) {
                out += makeActionGroup(pendingTools)
                pendingTools = mutableListOf()
            }
            out += SessionTranscriptSegment.Item(item)
        }
    }
    if (pendingTools.isNotEmpty()) {
        out += makeActionGroup(pendingTools)
    }
    return out
}

private fun makeActionGroup(
    tools: List<TranscriptItem.Tool>,
): SessionTranscriptSegment.Actions {
    val firstId = tools.firstOrNull()?.id ?: "empty"
    return SessionTranscriptSegment.Actions(id = "g-$firstId", tools = tools)
}

/**
 * Extension helpers that let the action-history views read tool
 * fields without re-implementing the case match everywhere. They are
 * safe for non-tool items (return null / 0).
 */
internal val TranscriptItem.toolName: String?
    get() = (this as? TranscriptItem.Tool)?.tool

internal val TranscriptItem.toolSummary: String?
    get() = (this as? TranscriptItem.Tool)?.summary

internal val TranscriptItem.toolOk: Boolean?
    get() = (this as? TranscriptItem.Tool)?.ok

internal val TranscriptItem.toolOutput: String?
    get() = (this as? TranscriptItem.Tool)?.output

internal fun TranscriptItem.toolId(): String? =
    (this as? TranscriptItem.Tool)?.id

/** Count of tool rows in `nil` (running) state — drives the spinner. */
internal fun List<TranscriptItem.Tool>.inFlightCount(): Int =
    count { it.ok == null }

/** Count of tool rows that finished successfully. */
internal fun List<TranscriptItem.Tool>.successCount(): Int =
    count { it.ok == true }

/** Count of tool rows that finished with an error. */
internal fun List<TranscriptItem.Tool>.failureCount(): Int =
    count { it.ok == false }

/**
 * The transcript's stable per-row key. Mirrors the iOS
 * `SessionViewModel.Item.id` for `LazyColumn` lookups.
 */
internal fun TranscriptItem.key(): String = when (this) {
    is TranscriptItem.User -> "u:" + text.hashCode()
    is TranscriptItem.Assistant -> "a:" + text.hashCode()
    is TranscriptItem.Tool -> "t:$id"
    is TranscriptItem.Diff -> "d:$id"
    is TranscriptItem.Notice -> "n:" + text.hashCode()
}
