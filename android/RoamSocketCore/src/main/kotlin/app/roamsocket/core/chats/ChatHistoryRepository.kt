package app.roamsocket.core.chats

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * In-memory chat-history surface that the UI consumes. The Android port
 * starts with a plain [MutableStateFlow] and an [apply] hook so the
 * Android app module can plug in its DataStore-backed persistence without
 * `RoamSocketCore` taking an Android dependency.
 *
 * Mirrors the public surface of the iOS `ChatHistoryStore`
 * (`ios/App/Sources/Features/Chats/ChatHistory.swift`). The published
 * [recents] list mirrors iOS's `activeRecents` — blank drafts are kept
 * internally (so they can be discarded cleanly) but hidden from the UI
 * until the first user message lands.
 */
public interface ChatHistoryRepository {
    /**
     * All non-archived, non-blank chats, newest-first. Blank drafts (the
     * user's just-opened "New chat") are filtered out so the sidebar
     * doesn't accumulate empty rows.
     */
    public val recents: StateFlow<List<ChatHistoryItem>>

    /**
     * Id of the chat the user is currently looking at, or null when on a
     * fresh blank chat. The host (`RootView`) drives this as the user
     * navigates.
     */
    public var activeChatId: String?

    /** Start a blank chat; returns the new id. */
    public fun startNewChat(): String

    /** Persist [messages] on the chat with [id] and refresh its title/time. */
    public fun saveMessages(id: String, messages: List<PersistedChatMessage>)

    /** Move an existing chat to the top of Recents and make it active. */
    public fun openChat(id: String)

    /** Forget the chat with [id]. No-op if it doesn't exist. */
    public fun deleteChat(id: String)

    /** Forget the active chat if it has no messages. */
    public fun discardActiveIfBlank()

    /**
     * Replace the in-memory list and notify observers. The Android app
     * module calls this once at startup after loading from disk so the
     * UI sees the persisted chats without an intermediate blank state.
     */
    public fun replaceAll(items: List<ChatHistoryItem>)

    /**
     * Snapshot of the current list. Includes blank drafts so the
     * Android app module can persist the full state (the active chat
     * may be a blank draft the user has yet to type into).
     */
    public fun snapshot(): List<ChatHistoryItem>
}

/**
 * Default in-memory implementation. Mutations always go through [mutate]
 * so the public [recents] flow stays in lock-step with the source list.
 */
public class InMemoryChatHistoryRepository : ChatHistoryRepository {
    private val _all = MutableStateFlow<List<ChatHistoryItem>>(emptyList())
    private val _recents = MutableStateFlow<List<ChatHistoryItem>>(emptyList())
    override val recents: StateFlow<List<ChatHistoryItem>> = _recents.asStateFlow()

    private var _activeChatId: String? = null
    override var activeChatId: String?
        get() = _activeChatId
        set(value) { _activeChatId = value }

    override fun startNewChat(): String {
        mutate { list ->
            list.removeAll { it.isBlankDraft }
            val now = System.currentTimeMillis()
            val item = ChatHistoryItem(
                id = newID(),
                title = ChatHistoryItem.DEFAULT_TITLE,
                lastMessageAtMillis = now,
            )
            list.add(0, item)
            _activeChatId = item.id
            item.id
        }
        return _activeChatId!!
    }

    override fun saveMessages(id: String, messages: List<PersistedChatMessage>) {
        mutate { list ->
            val idx = list.indexOfFirst { it.id == id }
            if (idx < 0) return@mutate
            val current = list[idx]
            val lastMessageAt = messages.lastOrNull()?.timestampMillis ?: current.lastMessageAtMillis
            val derivedTitle = if (
                current.title == ChatHistoryItem.DEFAULT_TITLE && messages.isNotEmpty()
            ) {
                derivedTitle(messages)
            } else {
                current.title
            }
            val updated = current.copy(
                messages = messages,
                lastMessageAtMillis = lastMessageAt,
                title = derivedTitle,
            )
            list.removeAt(idx)
            list.add(0, updated)
        }
    }

    override fun openChat(id: String) {
        mutate { list ->
            val idx = list.indexOfFirst { it.id == id }
            if (idx >= 0) {
                val existing = list.removeAt(idx)
                list.add(0, existing)
            } else {
                list.add(
                    0,
                    ChatHistoryItem(
                        id = id,
                        title = ChatHistoryItem.DEFAULT_TITLE,
                        lastMessageAtMillis = System.currentTimeMillis(),
                    ),
                )
            }
            _activeChatId = id
        }
    }

    override fun deleteChat(id: String) {
        mutate { list ->
            val before = list.size
            list.removeAll { it.id == id }
            if (list.size != before && _activeChatId == id) _activeChatId = null
        }
    }

    override fun discardActiveIfBlank() {
        val id = _activeChatId ?: return
        mutate { list ->
            val idx = list.indexOfFirst { it.id == id }
            if (idx < 0) return@mutate
            if (!list[idx].isBlankDraft) return@mutate
            list.removeAt(idx)
            _activeChatId = null
        }
    }

    override fun replaceAll(items: List<ChatHistoryItem>) {
        _all.value = items.sortedByDescending { it.lastMessageAtMillis }
        publishRecents()
    }

    override fun snapshot(): List<ChatHistoryItem> = _all.value

    /**
     * Single funnel for every mutation. Updates [_all], then re-publishes
     * the visible (non-archived, non-blank) subset on [_recents].
     */
    private inline fun mutate(block: (MutableList<ChatHistoryItem>) -> Unit) {
        val list = _all.value.toMutableList()
        block(list)
        _all.value = list
        publishRecents()
    }

    private fun publishRecents() {
        _recents.value = _all.value
            .asSequence()
            .filter { !it.isArchived && !it.isBlankDraft }
            .sortedByDescending { it.lastMessageAtMillis }
            .toList()
    }

    private fun derivedTitle(messages: List<PersistedChatMessage>): String {
        val firstUser = messages.firstOrNull { it.role == PersistedChatMessage.Role.USER }
            ?: return ChatHistoryItem.DEFAULT_TITLE
        val raw = firstUser.content.trim().replace(Regex("\\s+"), " ")
        if (raw.isEmpty()) return ChatHistoryItem.DEFAULT_TITLE
        // Mirror iOS's "first ~6 words" heuristic so the same chat gets the
        // same title in both apps. Truncate to 48 chars on a word boundary.
        val words = raw.split(' ').take(6).joinToString(" ")
        return if (words.length <= 48) {
            words
        } else {
            words.substring(0, 48).trimEnd { it == ' ' || it == ',' } + "…"
        }
    }

    private fun newID(): String = java.util.UUID.randomUUID().toString()
}
