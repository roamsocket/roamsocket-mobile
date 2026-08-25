package app.roamsocket.android.ui.artifacts

/**
 * A captured chat artifact — any assistant output the user might want to
 * revisit (long replies, code blocks, full reports). Opening an artifact
 * jumps back to the producing chat and (later) opens a split detail panel.
 *
 * Ports `Artifact` from
 * `ios/AnyProvCore/Sources/AnyProvCore/Artifacts/ArtifactStore.swift`.
 */
data class Artifact(
    val id: String,
    val createdAt: Long,
    /** Chat history id this artifact came from (for cross-reference). */
    val chatId: String?,
    /** Assistant message id that produced this artifact (scroll target). */
    val messageId: String?,
    /** Short display name, derived from the first line of the content. */
    var title: String,
    /** Full markdown content as returned by the assistant. */
    var content: String,
    /** Number of lines used to decide whether to save. */
    var lineCount: Int,
)

/** Default content threshold for the "auto-save" capture path. */
const val ARTIFACT_MIN_LINES: Int = 10
