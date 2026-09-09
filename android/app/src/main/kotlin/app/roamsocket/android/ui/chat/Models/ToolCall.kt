package app.roamsocket.android.ui.chat

/**
 * A tool step the assistant ran (or is running) for one turn. Mirrors
 * the iOS `ToolCall` struct in
 * `ios/App/Sources/Features/Chat/Models/ChatMessage.swift` 1:1 so the
 * Android renderer can surface grey tool-status lines under an
 * assistant message without re-deriving them from prose.
 *
 * Today only web-search / research / Wikipedia steps are wired up on
 * the Android side; the contract is shaped for the rest of the
 * connector tool set (bash / read_file / write_file / …) so adding
 * a new tool is a one-liner once those LLM providers land here.
 */
data class ToolCall(
    /** Stable id so a re-render during streaming doesn't re-create the row. */
    val id: String,
    /** Machine name (`web_search`, `wikipedia`, `research`, …). */
    val name: String,
    /** Human-readable grey line, e.g. `Searched the web for "…"`. */
    val summary: String,
    /** Optional secondary detail (source count, short extract). */
    val detail: String? = null,
    /** Final result body, set when [status] flips to [Status.Completed]. */
    val result: String? = null,
    /** Live status; mirrors the iOS `Status` enum (no separate Failed case
     *  because we surface the message inline in the rendered row). */
    val status: Status = Status.Pending,
) {
    /**
     * Mirrors the iOS `ToolCall.Status`. Sealed class so the renderer
     * can `when` over the cases exhaustively without losing the
     * `Failed(message)` payload.
     */
    sealed class Status {
        data object Pending : Status()
        data object Running : Status()
        data object Completed : Status()
        data class Failed(val message: String) : Status()
    }
}
