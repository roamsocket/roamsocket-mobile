package app.roamsocket.android.ui.browser

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Persists browser bookmarks, history, and approval-granularity preference
 * to a dedicated `DataStore<Preferences>` (separate from chat history so
 * clearing chats doesn't nuke saved bookmarks).
 *
 * Mirrors the iOS pattern in `BrowserStore` (UserDefaults keys prefixed
 * `browser.bookmarks.v1` / `browser.history.v1` / `browser.approvalGranularity.v1`).
 */
class BrowserPreferences(
    private val appContext: Context,
    private val appScope: CoroutineScope,
) {
    private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "browser")

    private val store = appContext.dataStore

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    @Serializable
    private data class BookmarkBlob(val items: List<BrowserBookmark>)

    @Serializable
    private data class HistoryBlob(val items: List<BrowserHistoryEntry>)

    private val keyBookmarks = stringPreferencesKey("browser.bookmarks.v1")
    private val keyHistory = stringPreferencesKey("browser.history.v1")
    private val keyGranularity = stringPreferencesKey("browser.approvalGranularity.v1")

    // In-memory mirrors so the store can read/write synchronously without
    // suspending for every UI mutation. The DataStore is the source of
    // truth; we load it once at startup and persist on every write.
    private val _bookmarks = MutableStateFlow<List<BrowserBookmark>>(emptyList())
    val bookmarks: StateFlow<List<BrowserBookmark>> = _bookmarks.asStateFlow()

    private val _history = MutableStateFlow<List<BrowserHistoryEntry>>(emptyList())
    val history: StateFlow<List<BrowserHistoryEntry>> = _history.asStateFlow()

    private val _granularity = MutableStateFlow(BrowserApprovalGranularity.BULK)
    val granularity: StateFlow<BrowserApprovalGranularity> = _granularity.asStateFlow()

    init {
        // Load once on construction. The DataStore reads are cheap but
        // they're async; we trigger them eagerly so the first UI render
        // already sees the persisted state.
        appScope.launch {
            loadAll()
        }
    }

    private suspend fun loadAll() {
        runCatching {
            val prefs = store.data.first()
            val rawBookmarks = prefs[keyBookmarks]
            if (rawBookmarks != null) {
                val blob = json.decodeFromString<BookmarkBlob>(rawBookmarks)
                _bookmarks.value = blob.items
            }
            val rawHistory = prefs[keyHistory]
            if (rawHistory != null) {
                val blob = json.decodeFromString<HistoryBlob>(rawHistory)
                _history.value = blob.items
            }
            val rawGranularity = prefs[keyGranularity]
            if (rawGranularity != null) {
                val parsed = runCatching { BrowserApprovalGranularity.valueOf(rawGranularity) }.getOrNull()
                if (parsed != null) _granularity.value = parsed
            }
        }
    }

    fun addBookmark(bookmark: BrowserBookmark) {
        if (_bookmarks.value.any { it.url == bookmark.url }) return
        _bookmarks.value = listOf(bookmark) + _bookmarks.value
        persistBookmarks()
    }

    fun removeBookmark(id: String) {
        _bookmarks.value = _bookmarks.value.filter { it.id != id }
        persistBookmarks()
    }

    fun addHistory(entry: BrowserHistoryEntry) {
        val without = _history.value.filter { it.url != entry.url }
        _history.value = (listOf(entry) + without).take(200)
        persistHistory()
    }

    fun clearHistory() {
        _history.value = emptyList()
        persistHistory()
    }

    fun setGranularity(granularity: BrowserApprovalGranularity) {
        _granularity.value = granularity
        appScope.launch {
            store.edit { prefs -> prefs[keyGranularity] = granularity.name }
        }
    }

    private fun persistBookmarks() {
        val snapshot = _bookmarks.value
        appScope.launch {
            runCatching {
                val blob = json.encodeToString(BookmarkBlob(snapshot))
                store.edit { prefs -> prefs[keyBookmarks] = blob }
            }
        }
    }

    private fun persistHistory() {
        val snapshot = _history.value
        appScope.launch {
            runCatching {
                val blob = json.encodeToString(HistoryBlob(snapshot))
                store.edit { prefs -> prefs[keyHistory] = blob }
            }
        }
    }
}
