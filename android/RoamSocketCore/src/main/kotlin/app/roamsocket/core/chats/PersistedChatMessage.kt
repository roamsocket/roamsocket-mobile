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
    /**
     * Assistant-only: the reasoning body extracted from the model
     * reply (e.g. Claude extended thinking, DeepSeek R1, Qwen3). The
     * chat surface renders this as the collapsed Thinking row.
     *
     * Persisted so the reasoning survives an app restart; older JSON
     * blobs deserialise cleanly because the field defaults to null.
     */
    val thoughtProcess: String? = null,
    /**
     * Assistant-only: a one-line heuristic label for the collapsed
     * Thinking row (e.g. "Picking the right index"). Computed on
     * stream complete; never re-derived on load. Optional — older
     * assistant turns without a summary fall back to deriving one
     * from [thoughtProcess] in the view layer.
     */
    val thoughtSummary: String? = null,
    /**
     * Assistant-only: lightweight tool steps the assistant ran
     * (web search, research, …) restored on reopen. Live running
     * state is dropped before persisting — the chat history only
     * stores the final (completed / failed) snapshot.
     */
    val toolSteps: List<PersistedToolStep> = emptyList(),
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

/**
 * Persistable tool step. Mirrors the iOS `PersistedToolStep` in
 * `ios/App/Sources/Features/Chats/ChatHistory.swift`. The live
 * [ToolCall] is richer (includes a running status, a result body, a
 * failed-message payload) but those fields aren't meaningful once
 * the chat is reloaded — only the rendered name / summary / detail
 * survive.
 */
@Serializable
public data class PersistedToolStep(
    val id: String,
    val name: String,
    val summary: String,
    val detail: String? = null,
)
