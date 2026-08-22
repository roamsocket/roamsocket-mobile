package app.roamsocket.core.code

import app.roamsocket.core.protocol.EnvironmentConfig
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Persisted record of a coding session. Mirrors the iOS `CodeSession`
 * (`ios/App/Sources/Features/Code/CodeHomeView.swift`) including the
 * transcript and environment fields needed to resume an archived
 * session on relaunch.
 *
 * Decoding is backward-compatible: archives created by the first
 * Android port (without transcript/environment/PR fields) still
 * load — see [init] for the defaults.
 */
@Serializable
public data class CodeSession(
    val id: String,
    val title: String,
    @SerialName("repoFullName") val repoFullName: String,
    @SerialName("baseBranch") val baseBranch: String,
    @SerialName("workBranch") val workBranch: String,
    val status: Status = Status.WORKING,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    /** Wire protocol session id used by the desktop SessionManager + tools. */
    val wireSessionId: String? = null,
    /** Environment locked in at create-time (matches iOS). */
    val environment: EnvironmentConfig? = null,
    /** Compare / pull-request URL after publish, if any. */
    val prURL: String? = null,
    /** Total tool-call count for the "Ready for review" filter heuristic. */
    val toolCount: Int = 0,
    /** Persisted transcript (kept when archived so chats survive disconnect). */
    val transcript: List<SessionTranscriptLine> = emptyList(),
    /** If true, leave the desktop agent alive until idle. */
    val disconnectWhenDone: Boolean = false,
    /** True only while the desktop agent is mid-turn (streaming / tools). */
    val agentActive: Boolean = false,
) {
    @Serializable
    public enum class Status {
        @SerialName("working") WORKING,
        @SerialName("needs_input") NEEDS_INPUT,
        @SerialName("ready_for_review") READY_FOR_REVIEW,
        @SerialName("completed") COMPLETED,
        @SerialName("archived") ARCHIVED,
        ;

        /** Short human label for the status pill in the Code home list. */
        public val displayName: String
            get() = when (this) {
                WORKING -> "Working"
                NEEDS_INPUT -> "Needs input"
                READY_FOR_REVIEW -> "Ready for review"
                COMPLETED -> "Completed"
                ARCHIVED -> "Archived"
            }
    }
}

/**
 * One line of a coding-session transcript, persisted with the session
 * so an archived chat can be re-opened exactly where the user left
 * off. Mirrors the iOS `SessionTranscriptLine` (`ios/.../CodeHomeView.swift`).
 *
 * The `id` prefix is stable: `u-` for user, `a-` for assistant,
 * `t-<callId>` for tool, `d-` for diff, `n-` for notice. This lets us
 * round-trip the call-id without a separate field.
 */
@Serializable
public data class SessionTranscriptLine(
    val id: String,
    val kind: Kind,
    val text: String,
    val tool: String? = null,
    val ok: Boolean? = null,
    val path: String? = null,
    val added: Int? = null,
    val removed: Int? = null,
) {
    @Serializable
    public enum class Kind {
        @SerialName("user") USER,
        @SerialName("assistant") ASSISTANT,
        @SerialName("tool") TOOL,
        @SerialName("diff") DIFF,
        @SerialName("notice") NOTICE,
    }
}
