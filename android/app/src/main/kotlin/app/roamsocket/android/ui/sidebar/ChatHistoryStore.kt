package app.roamsocket.android.ui.sidebar

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.mutableStateListOf
import java.util.UUID

/**
 * One row in the sidebar's "Recents" list. Mirrors the iOS `ChatHistoryItem`
 * (see `ios/App/Sources/Features/Chats/ChatHistory.swift`).
 */
@Immutable
data class ChatHistoryItem(
    val id: String,
    val title: String,
    val isStarred: Boolean = false,
    val isIncognito: Boolean = false,
    val isToolCall: Boolean = true,
    val updatedAtMillis: Long = System.currentTimeMillis(),
)

/**
 * Minimal in-memory chat history used to populate the sidebar's Recents list.
 *
 * On iOS this is backed by a persisted store (`ChatHistoryStore`); the Android
 * port starts as a tiny observable singleton that any chat surface can append
 * to via [rememberOrTouch]. Persistence is a follow-up; the goal of this
 * refactor is to wire the sidebar shell, not the data model.
 */
class ChatHistoryStore {
    private val _items = mutableStateListOf<ChatHistoryItem>()
    val items: List<ChatHistoryItem> get() = _items

    fun touch(title: String): ChatHistoryItem {
        val now = System.currentTimeMillis()
        val existing = _items.firstOrNull { it.title == title }
        if (existing != null) {
            val updated = existing.copy(updatedAtMillis = now)
            _items[_items.indexOf(existing)] = updated
            return updated
        }
        val created = ChatHistoryItem(
            id = UUID.randomUUID().toString(),
            title = title,
        )
        _items.add(0, created)
        return created
    }

    fun rename(id: String, title: String) {
        val idx = _items.indexOfFirst { it.id == id }
        if (idx >= 0) _items[idx] = _items[idx].copy(title = title)
    }

    fun setStarred(id: String, starred: Boolean) {
        val idx = _items.indexOfFirst { it.id == id }
        if (idx >= 0) _items[idx] = _items[idx].copy(isStarred = starred)
    }

    fun delete(id: String) {
        _items.removeAll { it.id == id }
    }

    fun archive(id: String) = delete(id)

    fun forgetChatNow(id: String) = delete(id)

    fun addChatToProject(@Suppress("UNUSED_PARAMETER") chatID: String, @Suppress("UNUSED_PARAMETER") projectID: String) {
        // Projects feature is iOS-only for now; this is a no-op on Android
        // so the sidebar's "Add to project" action still compiles.
    }

    /** Newest-first — matches what iOS renders in the Recents section. */
    val activeRecents: List<ChatHistoryItem>
        get() = _items.sortedByDescending { it.updatedAtMillis }
}
