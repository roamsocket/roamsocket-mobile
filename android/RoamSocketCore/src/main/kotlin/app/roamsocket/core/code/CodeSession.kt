package app.roamsocket.core.code

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Persisted record of a coding session. Mirrors the iOS `CodeSession`
 * (`ios/App/Sources/Features/Code/CodeHomeView.swift`) but stripped
 * down to the fields the Android port needs in the first iteration:
 * identity, repo, status, and timestamps.
 *
 * Fields the iOS version tracks (transcript, environment, PR URL,
 * tool count, …) are added in later PRs as the Session screen grows
 * to support them.
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
