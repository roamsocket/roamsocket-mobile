package app.roamsocket.android.data

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/** Top-level delegate that wires the DataStore to the Application context. */
private val Context.userDataStore by preferencesDataStore(name = "roamsocket_user_settings")

/**
 * Non-secret user preferences: current provider + model selection, custom
 * provider definitions, effort slider, etc. API keys live in
 * [EncryptedPrefsSecretStore] instead.
 */
class UserSettings(context: Context) {

    private val store = context.applicationContext.userDataStore

    val currentProvider: Flow<ProviderId> = store.data.map { prefs ->
        prefs[KEY_PROVIDER]?.let(ProviderId::fromRawValue) ?: ProviderId.Anthropic
    }

    val currentModel: Flow<String> = store.data.map { prefs ->
        prefs[KEY_MODEL] ?: DEFAULT_MODEL
    }

    suspend fun setCurrent(provider: ProviderId, model: String) {
        store.edit { prefs ->
            prefs[KEY_PROVIDER] = provider.rawValue
            prefs[KEY_MODEL] = model
        }
    }

    private companion object {
        val KEY_PROVIDER: Preferences.Key<String> = stringPreferencesKey("current_provider")
        val KEY_MODEL: Preferences.Key<String> = stringPreferencesKey("current_model")
        const val DEFAULT_MODEL = "claude-3-5-sonnet-20241022"
    }
}
