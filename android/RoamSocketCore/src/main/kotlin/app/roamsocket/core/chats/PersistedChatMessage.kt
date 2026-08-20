package app.roamsocket.core.chats

import kotlinx.serialization.Serializable

/**
 * On-disk shape of a single chat turn. Mirrors the iOS
 * `PersistedChatMessage` in `ios/App/Sources/Features/Chats/ChatHistory.swift`.
 *
 * Kept deliberately narrow in this first port — text + role + timestamp —
 * so we can land persistence without dragging in the full thinking /
 * tool-step schema. Subsequent PRs will extend the model as the chat
 * screen grows (PR 7: image attachments, PR 22: memory activity, …).
 */
@Serializable
public data class PersistedChatMessage(
    val id: String,
    val role: Role,
    val content: String,
    val timestampMillis: Long,
) {
    @Serializable
    public enum class Role {
        @kotlinx.serialization.SerialName("user") USER,
        @kotlinx.serialization.SerialName("assistant") ASSISTANT,
        @kotlinx.serialization.SerialName("system") SYSTEM,
        ;
    }
}
