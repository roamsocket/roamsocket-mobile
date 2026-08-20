package app.roamsocket.core.chats

import app.roamsocket.core.providers.ProviderId
import kotlinx.serialization.Serializable

/**
 * On-disk shape of a single chat shown in the sidebar's Recents list.
 * Mirrors the iOS `ChatHistoryItem`
 * (`ios/App/Sources/Features/Chats/ChatHistory.swift`).
 */
@Serializable
public data class ChatHistoryItem(
    val id: String,
    val title: String,
    val lastMessageAtMillis: Long,
    val messages: List<PersistedChatMessage> = emptyList(),
    val isArchived: Boolean = false,
    /**
     * Per-chat provider + model selection (port #9: per-chat model
     * selection). When set, opening the chat restores both fields; when
     * null the global default wins. The selection is stored as a
     * plain `provider` + `model` pair rather than the full `AIModel`
     * because the catalog can change between releases and we only need
     * the identifiers to look the model back up at resume time.
     */
    val selectedProvider: String? = null,
    val selectedModel: String? = null,
) {
    /** Stable identity for diffing. Matches the on-disk `id`. */
    val stableID: String get() = id

    /** A "blank draft" has no messages yet and stays hidden from Recents. */
    val isBlankDraft: Boolean get() = messages.isEmpty()

    /** True when the user picked a non-default model for this chat. */
    val hasModelOverride: Boolean
        get() = !selectedProvider.isNullOrEmpty() && !selectedModel.isNullOrEmpty()

    /** Resolve the persisted selection back to a [ProviderId], if any. */
    val resolvedProvider: ProviderId?
        get() = selectedProvider?.let { ProviderId.fromRawValue(it) }

    public companion object {
        /** Default title shown in the sidebar before auto-titling kicks in. */
        public const val DEFAULT_TITLE: String = "New chat"
    }
}
