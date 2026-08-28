package app.roamsocket.android.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
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

    val hasKeyFlow: Flow<Boolean> = store.data.map { prefs ->
        !prefs[KEY].isNullOrEmpty()
    }

    suspend fun get(): String? =
        store.data.first()[KEY]?.takeIf { it.isNotBlank() }

    suspend fun set(value: String?) {
        val trimmed = value?.trim().orEmpty()
        store.edit { prefs ->
            if (trimmed.isEmpty()) prefs.remove(KEY) else prefs[KEY] = trimmed
        }
    }

    private companion object {
        val KEY = stringPreferencesKey("e2b_api_key")
    }
}
