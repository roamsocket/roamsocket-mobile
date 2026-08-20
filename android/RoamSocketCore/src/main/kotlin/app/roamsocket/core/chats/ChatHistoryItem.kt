package app.roamsocket.core.chats

import kotlinx.serialization.Serializable

/**
 * On-disk shape of a single chat shown in the sidebar's Recents list.
 * Mirrors the iOS `ChatHistoryItem`
 * (`ios/App/Sources/Features/Chats/ChatHistory.swift`).
 *
 * The first Android port keeps the schema narrow on purpose: only fields
 * needed for "open a recent → resume the transcript" land here. Per-chat
 * model selection, incognito lifetime, projects, etc. are added in
 * subsequent PRs.
 */
@Serializable
public data class ChatHistoryItem(
    val id: String,
    val title: String,
    val lastMessageAtMillis: Long,
    val messages: List<PersistedChatMessage> = emptyList(),
    val isArchived: Boolean = false,
) {
    /** Stable identity for diffing. Matches the on-disk `id`. */
    val stableID: String get() = id

    /** A "blank draft" has no messages yet and stays hidden from Recents. */
    val isBlankDraft: Boolean get() = messages.isEmpty()

    public companion object {
        /** Default title shown in the sidebar before auto-titling kicks in. */
        public const val DEFAULT_TITLE: String = "New chat"
    }
}
