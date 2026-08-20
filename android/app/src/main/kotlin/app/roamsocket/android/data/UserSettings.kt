package app.roamsocket.android.data

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/** Top-level delegate that wires the DataStore to the Application context. */
private val Context.userDataStore by preferencesDataStore(name = "roamsocket_user_settings")

/**
 * How much of the desktop agent's tool surface the chat is allowed to
 * invoke. Mirrors the iOS `ToolAccessLevel` enum used in the same
 * "Add to Chat" sheet. The names are stable strings so we can persist
 * them as-is and rename display strings later.
 */
enum class ToolAccessLevel(val raw: String, val display: String, val description: String) {
    Auto("auto", "Auto", "Let the model decide which tools to use."),
    ReadOnly("readonly", "Read-only", "Only tools that read project state. No writes."),
    Full("full", "Full", "All tools, including writes. Most capable, most risk.");

    companion object {
        fun fromRaw(raw: String?): ToolAccessLevel =
            values().firstOrNull { it.raw == raw } ?: Auto
    }
}

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

    // ----- Add-to-Chat preferences (port #12) -----

    val researchEnabled: Flow<Boolean> = store.data.map { prefs ->
        prefs[KEY_RESEARCH] ?: false
    }

    suspend fun setResearchEnabled(enabled: Boolean) {
        store.edit { prefs -> prefs[KEY_RESEARCH] = enabled }
    }

    val webSearchEnabled: Flow<Boolean> = store.data.map { prefs ->
        prefs[KEY_WEB_SEARCH] ?: false
    }

    suspend fun setWebSearchEnabled(enabled: Boolean) {
        store.edit { prefs -> prefs[KEY_WEB_SEARCH] = enabled }
    }

    val locationEnabled: Flow<Boolean> = store.data.map { prefs ->
        prefs[KEY_LOCATION] ?: false
    }

    suspend fun setLocationEnabled(enabled: Boolean) {
        store.edit { prefs -> prefs[KEY_LOCATION] = enabled }
    }

    val toolAccess: Flow<ToolAccessLevel> = store.data.map { prefs ->
        ToolAccessLevel.fromRaw(prefs[KEY_TOOL_ACCESS])
    }

    suspend fun setToolAccess(level: ToolAccessLevel) {
        store.edit { prefs -> prefs[KEY_TOOL_ACCESS] = level.raw }
    }

    private companion object {
        val KEY_PROVIDER: Preferences.Key<String> = stringPreferencesKey("current_provider")
        val KEY_MODEL: Preferences.Key<String> = stringPreferencesKey("current_model")
        val KEY_RESEARCH: Preferences.Key<Boolean> = booleanPreferencesKey("research_enabled")
        val KEY_WEB_SEARCH: Preferences.Key<Boolean> = booleanPreferencesKey("web_search_enabled")
        val KEY_LOCATION: Preferences.Key<Boolean> = booleanPreferencesKey("location_enabled")
        val KEY_TOOL_ACCESS: Preferences.Key<String> = stringPreferencesKey("tool_access")
        const val DEFAULT_MODEL = "claude-3-5-sonnet-20241022"
    }
}
