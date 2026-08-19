package app.roamsocket.android.data

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.roamsocket.core.server.Endpoint
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

private val Context.pairedDataStore by preferencesDataStore(name = "roamsocket_paired_server")

/**
 * Persisted paired-server record: the endpoint, bearer token, server name,
 * server version, and optional public URL. All fields except endpoint +
 * token are display-only.
 */
@Serializable
data class PairedServer(
    val endpoint: String,
    val token: String,
    val serverName: String,
    val serverVersion: String,
    val publicUrl: String? = null,
    val pairedAtEpochMs: Long = System.currentTimeMillis(),
)

/** Reads / writes the active paired server. Exactly one record at a time. */
class PairedServerStore(context: Context) {

    private val store = context.applicationContext.pairedDataStore
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    val paired: Flow<PairedServer?> = store.data.map { prefs ->
        prefs[KEY_JSON]?.let { runCatching { json.decodeFromString(PairedServer.serializer(), it) }.getOrNull() }
    }

    suspend fun current(): PairedServer? = paired.first()

    suspend fun save(server: PairedServer) {
        store.edit { prefs -> prefs[KEY_JSON] = json.encodeToString(PairedServer.serializer(), server) }
    }

    suspend fun clear() {
        store.edit { prefs -> prefs.remove(KEY_JSON) }
    }

    private companion object {
        val KEY_JSON: Preferences.Key<String> = stringPreferencesKey("paired_server_json")
    }
}

/** Convenience: parse an [Endpoint] from the persisted baseURL on demand. */
fun PairedServer.toEndpoint(): Endpoint? = Endpoint.fromHost(endpoint)
