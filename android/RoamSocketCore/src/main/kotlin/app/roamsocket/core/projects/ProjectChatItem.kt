package app.roamsocket.core.projects

import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import kotlinx.serialization.Serializable

/**
 * A chat that lives inside a project. Mirrors the iOS
 * `ProjectChatItem` 1:1. `selectedModel` is `AIModel?` to match
 * iOS (the existing `ChatHistoryItem` uses a two-string
 * `(provider, modelID)` split; that is normalized in a later phase).
 */
@Serializable
data class ProjectChatItem(
    val id: String,
    val title: String,
    val lastMessageAtMillis: Long,
    val messages: List<PersistedChatMessage> = emptyList(),
    val isArchived: Boolean = false,
    val selectedModel: AIModel? = null,
    val titleIsUserEdited: Boolean = false,
    val didAutoTitle: Boolean = false,
    val autoTitleAtUserCount: Int = 0,
)
