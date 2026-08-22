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
 * Reasoning effort hint passed through to providers that understand
 * `effort` (Anthropic, OpenAI, Google). Mirrors the iOS `Effort` enum.
 * Providers that don't honour the field just ignore it.
 */
enum class EffortLevel(val raw: String, val display: String, val description: String) {
    Low("low", "Low", "Fastest replies, lightest reasoning."),
    Medium("medium", "Medium", "Balanced speed and depth."),
    High("high", "High", "Most thorough reasoning; slowest.");

    companion object {
        fun fromRaw(raw: String?): EffortLevel =
            values().firstOrNull { it.raw == raw } ?: High
    }
}

/**
 * Visual theme for the app. Mirrors the iOS `AppAppearance` enum.
 * `Auto` follows the system dark-mode setting; the Android equivalent
 * is `Configuration.UI_MODE_NIGHT_MASK`.
 */
enum class AppAppearance(val raw: String, val display: String) {
    System("system", "System"),
    Light("light", "Light"),
    Dark("dark", "Dark");

    companion object {
        fun fromRaw(raw: String?): AppAppearance =
            values().firstOrNull { it.raw == raw } ?: System
    }
}

/**
 * Which voice / TTS provider powers the chat voice replies. Mirrors
 * the iOS `VoiceSettingsStore` selection.
 */
enum class VoiceProvider(val raw: String, val display: String) {
    FreeNeural("free_neural", "Free neural"),
    OpenAITTS("openai_tts", "OpenAI TTS"),
    ElevenLabs("elevenlabs", "ElevenLabs");

    companion object {
        fun fromRaw(raw: String?): VoiceProvider =
            values().firstOrNull { it.raw == raw } ?: FreeNeural
    }
}

/**
 * Non-secret user preferences: current provider + model selection, custom
 * provider definitions, effort slider, appearance, voice settings, etc.
 * API keys live in [EncryptedPrefsSecretStore] instead.
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

    // ----- Settings parity (PR — settings wiring) -----

    /** When true, the chat transcript always expands the model's reasoning
     *  trace under the summary row (port from iOS `alwaysExpandThinking`). */
    val alwaysExpandThinking: Flow<Boolean> = store.data.map { prefs ->
        prefs[KEY_ALWAYS_EXPAND_THINKING] ?: false
    }

    suspend fun setAlwaysExpandThinking(enabled: Boolean) {
        store.edit { prefs -> prefs[KEY_ALWAYS_EXPAND_THINKING] = enabled }
    }

    /** Default reasoning effort for the chat composer; can be overridden
     *  per-message in the Add to Chat sheet (port from iOS `effort`). */
    val effort: Flow<EffortLevel> = store.data.map { prefs ->
        EffortLevel.fromRaw(prefs[KEY_EFFORT])
    }

    suspend fun setEffort(level: EffortLevel) {
        store.edit { prefs -> prefs[KEY_EFFORT] = level.raw }
    }

    /** Branch prefix used for new coding-session branches
     *  (port from iOS `codeBranchPrefix`). */
    val branchPrefix: Flow<String> = store.data.map { prefs ->
        prefs[KEY_BRANCH_PREFIX]?.takeIf { it.isNotBlank() } ?: DEFAULT_BRANCH_PREFIX
    }

    suspend fun setBranchPrefix(value: String) {
        val trimmed = value.trim().take(MAX_BRANCH_PREFIX_LEN)
        val safe = trimmed.ifBlank { DEFAULT_BRANCH_PREFIX }
        store.edit { prefs -> prefs[KEY_BRANCH_PREFIX] = safe }
    }

    /** Light / Dark / System preference (port from iOS `appearance`). */
    val appearance: Flow<AppAppearance> = store.data.map { prefs ->
        AppAppearance.fromRaw(prefs[KEY_APPEARANCE])
    }

    suspend fun setAppearance(appearance: AppAppearance) {
        store.edit { prefs -> prefs[KEY_APPEARANCE] = appearance.raw }
    }

    /** Selected TTS provider for voice chat. */
    val voiceProvider: Flow<VoiceProvider> = store.data.map { prefs ->
        VoiceProvider.fromRaw(prefs[KEY_VOICE_PROVIDER])
    }

    suspend fun setVoiceProvider(provider: VoiceProvider) {
        store.edit { prefs -> prefs[KEY_VOICE_PROVIDER] = provider.raw }
    }

    /** OpenAI TTS model id (e.g. "tts-1", "tts-1-hd", "gpt-4o-mini-tts").
     *  Defaults to "tts-1" to match the iOS voice settings store. */
    val voiceOpenAIModel: Flow<String> = store.data.map { prefs ->
        prefs[KEY_VOICE_OPENAI_MODEL]?.takeIf { it.isNotBlank() } ?: DEFAULT_VOICE_OPENAI_MODEL
    }

    suspend fun setVoiceOpenAIModel(model: String) {
        val safe = model.trim().take(MAX_VOICE_MODEL_LEN).ifBlank { DEFAULT_VOICE_OPENAI_MODEL }
        store.edit { prefs -> prefs[KEY_VOICE_OPENAI_MODEL] = safe }
    }

    private companion object {
        val KEY_PROVIDER: Preferences.Key<String> = stringPreferencesKey("current_provider")
        val KEY_MODEL: Preferences.Key<String> = stringPreferencesKey("current_model")
        val KEY_RESEARCH: Preferences.Key<Boolean> = booleanPreferencesKey("research_enabled")
        val KEY_WEB_SEARCH: Preferences.Key<Boolean> = booleanPreferencesKey("web_search_enabled")
        val KEY_LOCATION: Preferences.Key<Boolean> = booleanPreferencesKey("location_enabled")
        val KEY_TOOL_ACCESS: Preferences.Key<String> = stringPreferencesKey("tool_access")

        val KEY_ALWAYS_EXPAND_THINKING: Preferences.Key<Boolean> =
            booleanPreferencesKey("always_expand_thinking")
        val KEY_EFFORT: Preferences.Key<String> = stringPreferencesKey("effort")
        val KEY_BRANCH_PREFIX: Preferences.Key<String> = stringPreferencesKey("branch_prefix")
        val KEY_APPEARANCE: Preferences.Key<String> = stringPreferencesKey("appearance")
        val KEY_VOICE_PROVIDER: Preferences.Key<String> = stringPreferencesKey("voice_provider")
        val KEY_VOICE_OPENAI_MODEL: Preferences.Key<String> =
            stringPreferencesKey("voice_openai_model")

        const val DEFAULT_MODEL = "claude-3-5-sonnet-20241022"
        const val DEFAULT_BRANCH_PREFIX = "roamsocket"
        const val DEFAULT_VOICE_OPENAI_MODEL = "tts-1"
        const val MAX_BRANCH_PREFIX_LEN = 40
        const val MAX_VOICE_MODEL_LEN = 60
    }
}
