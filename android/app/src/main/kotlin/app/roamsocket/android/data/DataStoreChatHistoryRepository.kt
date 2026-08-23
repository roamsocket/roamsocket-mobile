package app.roamsocket.android.data

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.roamsocket.core.chats.ChatHistoryItem
import app.roamsocket.core.chats.ChatHistoryRepository
import app.roamsocket.core.chats.InMemoryChatHistoryRepository
import app.roamsocket.core.chats.PersistedChatMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

private val Context.chatHistoryDataStore by preferencesDataStore(name = "roamsocket_chat_history")

/**
 * DataStore-backed chat history. Stores the full list of chats as a
 * single JSON blob under one preference key.
 *
 * The list is loaded into memory on first access; subsequent mutations
 * are applied in memory and the latest snapshot is written back to disk.
 * This mirrors the iOS `ChatHistoryStore` save/load strategy
 * (`ios/App/Sources/Features/Chats/ChatHistory.swift`), where UserDefaults
 * holds one big JSON blob and the in-memory list is the source of truth
 * at runtime.
 *
 * The wrapper also exposes the underlying [recents] / [activeChatId] as
 * a `StateFlow` so the Compose `SidebarView` and `ChatView` can collect
 * updates without spinning up their own coroutine.
 */
class DataStoreChatHistoryRepository(
    context: Context,
    /** Long-lived scope for the load + persist-on-change collectors. */
    private val flowScope: CoroutineScope,
    /** Override the JSON codec; lets tests plug in their own. */
    private val json: Json = DEFAULT_JSON,
) : ChatHistoryRepository {

    private val store = context.applicationContext.chatHistoryDataStore

    // Internal in-memory source of truth (also exposed as the public
    // [recents] flow via a derived StateFlow). Seeded by [loadInitial].
    private val inMemory = InMemoryChatHistoryRepository()

    // Whether we've finished loading from disk; mutations before this
    // are buffered by the in-memory repo.
    private val ready = MutableStateFlow(false)

    init {
        // Kick off the one-time load. Mutations made before it finishes
        // are queued by the in-memory repo and persisted once the
        // collector below starts mirroring.
        flowScope.launch {
            val items = readFromDisk()
            inMemory.replaceAll(items)
            ready.value = true
        }
        // Every time the in-memory recents list changes, mirror to disk.
        // The first emission after `ready` flips includes any queued
        // mutations from before the load finished, so the very first
        // save carries the freshest state.
        flowScope.launch {
            inMemory.recents.collect {
                if (ready.value) writeToDisk(inMemory.snapshot())
            }
        }
    }

    override val recents: StateFlow<List<ChatHistoryItem>> = inMemory.recents
    override var activeChatId: String?
        get() = inMemory.activeChatId
        set(value) { inMemory.activeChatId = value }

    override fun startNewChat(): String = inMemory.startNewChat()

    override fun saveMessages(id: String, messages: List<PersistedChatMessage>) =
        inMemory.saveMessages(id, messages)

    override fun openChat(id: String) = inMemory.openChat(id)

    override fun setModel(
        id: String,
        provider: app.roamsocket.core.providers.ProviderId,
        model: String,
    ) = inMemory.setModel(id, provider, model)

    override fun deleteChat(id: String) = inMemory.deleteChat(id)

    override fun discardActiveIfBlank() = inMemory.discardActiveIfBlank()

    override fun replaceAll(items: List<ChatHistoryItem>) = inMemory.replaceAll(items)

    override fun snapshot(): List<ChatHistoryItem> = inMemory.snapshot()

    override fun startIncognitoChat(lifetime: app.roamsocket.core.chats.IncognitoLifetime): String =
        inMemory.startIncognitoChat(lifetime)

    override fun setIncognitoLifetime(
        id: String,
        lifetime: app.roamsocket.core.chats.IncognitoLifetime,
    ) = inMemory.setIncognitoLifetime(id, lifetime)

    override fun forgetChatNow(id: String) = inMemory.forgetChatNow(id)

    override fun forgetActiveIfOnExit() = inMemory.forgetActiveIfOnExit()

    override fun pruneExpiredIncognito(): List<String> = inMemory.pruneExpiredIncognito()

    /** Force a synchronous load (mostly useful for tests). */
    suspend fun awaitReady() {
        if (ready.value) return
        ready.first { it }
    }

    private suspend fun readFromDisk(): List<ChatHistoryItem> {
        val raw = store.data.first()[KEY_JSON] ?: return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(ChatHistoryItem.serializer()), raw)
        }.getOrDefault(emptyList())
    }

    private suspend fun writeToDisk(items: List<ChatHistoryItem>) {
        val encoded = json.encodeToString(ListSerializer(ChatHistoryItem.serializer()), items)
        store.edit { prefs -> prefs[KEY_JSON] = encoded }
    }

    companion object {
        private val DEFAULT_JSON = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            prettyPrint = false
        }
        private val KEY_JSON: Preferences.Key<String> = stringPreferencesKey("chat_history_json")
    }
}
