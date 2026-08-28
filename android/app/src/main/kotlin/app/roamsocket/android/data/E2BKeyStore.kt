package app.roamsocket.android.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.e2bKeyDataStore by preferencesDataStore(name = "roamsocket_e2b_key")

/**
 * Local-only store for the user's e2b.dev API key. The phone uses it
 * to spin up sandboxes directly via e2b.dev (no paired desktop).
 * Mirrors the iOS `E2BKeyStore` in
 * `ios/AnyProvCore/.../Sandboxes/E2BKeyStore.swift`.
 */
class E2BKeyStore(context: Context) {
    private val store = context.applicationContext.e2bKeyDataStore

    /** Synchronous snapshot at construction time. The Compose UI
     *  reads [hasKeyFlow] to react to changes. */
    val initialHasKey = MutableStateFlow(readSync())

    val hasKeyFlow: Flow<Boolean> = store.data.map { prefs ->
        !prefs[KEY].isNullOrEmpty()
    }

    suspend fun get(): String? {
        return store.data.first()[KEY]?.takeIf { it.isNotBlank() }
    }

    suspend fun set(value: String?) {
        val trimmed = value?.trim().orEmpty()
        store.edit { prefs ->
            if (trimmed.isEmpty()) prefs.remove(KEY) else prefs[KEY] = trimmed
        }
        initialHasKey.value = trimmed.isNotEmpty()
    }

    private fun readSync(): Boolean {
        // Best-effort synchronous read; the value comes from DataStore
        // so this is only used as a seed for the initial state. The
        // Compose UI should always read the latest value from
        // [hasKeyFlow] before deciding to gate anything.
        return false
    }

    private companion object {
        val KEY = stringPreferencesKey("e2b_api_key")
    }
}
