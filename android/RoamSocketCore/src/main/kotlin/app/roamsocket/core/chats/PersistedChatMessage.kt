package app.roamsocket.core.chats

import kotlinx.serialization.Serializable

/**
 * On-disk shape of a single chat turn. Mirrors the iOS
 * `PersistedChatMessage` in `ios/App/Sources/Features/Chats/ChatHistory.swift`.
 */
@Serializable
public data class PersistedChatMessage(
    val id: String,
    val role: Role,
    val content: String,
    val timestampMillis: Long,
    /**
     * Delivery state for this turn. Defaults to [Delivery.SENT] for
     * legacy rows so an older JSON blob deserializes cleanly. A user
     * turn is written with [Delivery.PENDING] when the user hits send
     * (before the API call) and updated to [Delivery.FAILED] with a
     * reason when the request errors; the UI uses this to render a
     * retry button. Assistant turns are always [Delivery.SENT].
     */
    val delivery: Delivery = Delivery.SENT,
) {
    @Serializable
    public enum class Role {
        @kotlinx.serialization.SerialName("user") USER,
        @kotlinx.serialization.SerialName("assistant") ASSISTANT,
        @kotlinx.serialization.SerialName("system") SYSTEM,
        ;
    }

    @Serializable
    public enum class Delivery {
        /** Default — the message was sent and acknowledged (or it's an assistant reply). */
        @kotlinx.serialization.SerialName("sent") SENT,
        /** User message: written to the repo, waiting for the API response. */
        @kotlinx.serialization.SerialName("pending") PENDING,
        /** User message: the API call failed. [failureReason] on the parent may have a hint. */
        @kotlinx.serialization.SerialName("failed") FAILED,
        ;
    }
}
