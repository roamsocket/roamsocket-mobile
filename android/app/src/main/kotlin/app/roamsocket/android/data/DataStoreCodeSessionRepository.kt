package app.roamsocket.android.data

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.roamsocket.core.code.CodeSession
import app.roamsocket.core.code.CodeSessionRepository
import app.roamsocket.core.code.InMemoryCodeSessionRepository
import app.roamsocket.core.code.SessionTranscriptLine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

private val Context.codeSessionDataStore by preferencesDataStore(name = "roamsocket_code_sessions")

/**
 * DataStore-backed code session list. Same single-JSON-blob strategy
 * as `DataStoreChatHistoryRepository`: load on first access, mirror
 * every mutation back to disk via a long-lived collector.
 */
class DataStoreCodeSessionRepository(
    context: Context,
    private val flowScope: CoroutineScope,
    private val json: Json = DEFAULT_JSON,
) : CodeSessionRepository {

    private val store = context.applicationContext.codeSessionDataStore
    private val inMemory = InMemoryCodeSessionRepository()
    private val ready = MutableStateFlow(false)

    init {
        flowScope.launch {
            val items = readFromDisk()
            // Agent mid-turn state does not survive process restart (the
            // socket is gone; user would see a phantom "Working" pill).
            // Matches iOS `CodeSessionStore.load`.
            val normalized = items.map { it.copy(agentActive = false) }
            inMemory.replaceAll(normalized)
            if (normalized != items) writeToDisk(normalized)
            ready.value = true
        }
        // Persist on every active/archived change. Same coalescing story
        // as the chat history wrapper — small JSON blob, every write
        // is cheap.
        flowScope.launch {
            inMemory.active.collect {
                if (ready.value) writeToDisk(inMemory.snapshot())
            }
        }
        flowScope.launch {
            inMemory.archived.collect {
                if (ready.value) writeToDisk(inMemory.snapshot())
            }
        }
    }

    override val active: StateFlow<List<CodeSession>> = inMemory.active
    override val archived: StateFlow<List<CodeSession>> = inMemory.archived

    override fun add(session: CodeSession) = inMemory.add(session)
    override fun update(id: String, mutate: (CodeSession) -> CodeSession) = inMemory.update(id, mutate)
    override fun archive(id: String) = inMemory.archive(id)
    override fun archive(id: String, disconnectWhenDone: Boolean) = inMemory.archive(id, disconnectWhenDone)
    override fun unarchive(id: String) = inMemory.unarchive(id)
    override fun setAgentActive(id: String, active: Boolean) = inMemory.setAgentActive(id, active)
    override fun saveTranscript(id: String, lines: List<SessionTranscriptLine>) = inMemory.saveTranscript(id, lines)
    override fun rename(id: String, title: String) = inMemory.rename(id, title)
    override fun delete(id: String) = inMemory.delete(id)
    override fun replaceAll(sessions: List<CodeSession>) = inMemory.replaceAll(sessions)
    override fun snapshot(): List<CodeSession> = inMemory.snapshot()

    suspend fun awaitReady() {
        if (ready.value) return
        ready.first { it }
    }

    private suspend fun readFromDisk(): List<CodeSession> {
        val raw = store.data.first()[KEY_JSON] ?: return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(CodeSession.serializer()), raw)
        }.getOrDefault(emptyList())
    }

    private suspend fun writeToDisk(items: List<CodeSession>) {
        val encoded = json.encodeToString(ListSerializer(CodeSession.serializer()), items)
        store.edit { prefs -> prefs[KEY_JSON] = encoded }
    }

    companion object {
        private val DEFAULT_JSON = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            prettyPrint = false
        }
        private val KEY_JSON: Preferences.Key<String> = stringPreferencesKey("code_sessions_json")
    }
}
