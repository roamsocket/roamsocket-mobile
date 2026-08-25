package app.roamsocket.android.ui.lightweight

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/**
 * User preferences for short helper generations
 * (chat titles, artifact names, commit subjects, thinking summaries).
 *
 * The iOS app has two backends — Apple Intelligence (on-device) and a
 * user-linked BYOK model. Android has no Foundation-Model equivalent
 * today, so the [Mode.LINKED_MODEL] path is the only one we expose.
 * The data shape mirrors `ios/.../LightweightTasks/LightweightTasksSettings.swift`
 * (with the Apple Intelligence enum case dropped) so a future on-device
 * backend can plug in without rewriting the call sites.
 *
 * Storage: SharedPreferences at `lightweightTasks.v1` (same key the iOS
 * app uses, so a cross-platform sync layer can share the blob).
 */
data class LightweightTasksSettings(
    val mode: Mode = Mode.LINKED_MODEL,
    /** [ProviderId.rawValue] when [mode] is [Mode.LINKED_MODEL]. */
    val linkedProviderRaw: String? = null,
    val linkedModelID: String? = null,
    /** First-launch walkthrough finished. */
    val walkthroughCompleted: Boolean = false,
) {
    enum class Mode {
        LINKED_MODEL,
        ;

        val displayName: String
            get() = when (this) {
                LINKED_MODEL -> "Linked model"
            }

        val detail: String
            get() = when (this) {
                LINKED_MODEL -> "Uses a provider and model you choose (and pay for). Works on any device with an API key."
            }
    }

    val linkedProvider: ProviderId?
        get() = linkedProviderRaw?.let { runCatching { ProviderId.fromRawValue(it) }.getOrNull() }

    val hasLinkedModel: Boolean
        get() = mode == Mode.LINKED_MODEL &&
            linkedProvider != null &&
            !(linkedModelID.isNullOrEmpty())

    companion object {
        const val STORAGE_KEY: String = "lightweightTasks.v1"

        val Default: LightweightTasksSettings = LightweightTasksSettings()
    }
}

/**
 * Persists [LightweightTasksSettings] in SharedPreferences. Survives app
 * restarts and is observed by the walkthrough (which only shows on
 * first launch) and by the runner (which reads the linked-model config).
 *
 * Mirrors the static `load()` / `save()` helpers on
 * `ios/.../LightweightTasks/LightweightTasksSettings.swift`.
 */
class LightweightTasksStore(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences(LightweightTasksSettings.STORAGE_KEY, Context.MODE_PRIVATE)

    private val _settings = MutableStateFlow(load())
    val settings: StateFlow<LightweightTasksSettings> = _settings.asStateFlow()

    fun update(transform: (LightweightTasksSettings) -> LightweightTasksSettings) {
        val next = transform(_settings.value)
        if (next == _settings.value) return
        _settings.value = next
        save(next)
    }

    fun reset() {
        _settings.value = LightweightTasksSettings.Default
        save(LightweightTasksSettings.Default)
    }

    // ------------------------------------------------------------------
    // Persistence
    // ------------------------------------------------------------------

    private fun load(): LightweightTasksSettings {
        val raw = prefs.getString(KEY_PAYLOAD, null) ?: return LightweightTasksSettings.Default
        return try {
            val obj = JSONObject(raw)
            val modeRaw = obj.optString(KEY_MODE, LightweightTasksSettings.Mode.LINKED_MODEL.name)
            val mode = runCatching { LightweightTasksSettings.Mode.valueOf(modeRaw) }
                .getOrDefault(LightweightTasksSettings.Mode.LINKED_MODEL)
            LightweightTasksSettings(
                mode = mode,
                linkedProviderRaw = obj.optString(KEY_LINKED_PROVIDER, "").takeIf { it.isNotEmpty() },
                linkedModelID = obj.optString(KEY_LINKED_MODEL, "").takeIf { it.isNotEmpty() },
                walkthroughCompleted = obj.optBoolean(KEY_WALKTHROUGH, false),
            )
        } catch (_: Throwable) {
            LightweightTasksSettings.Default
        }
    }

    private fun save(value: LightweightTasksSettings) {
        val obj = JSONObject().apply {
            put(KEY_MODE, value.mode.name)
            put(KEY_LINKED_PROVIDER, value.linkedProviderRaw ?: "")
            put(KEY_LINKED_MODEL, value.linkedModelID ?: "")
            put(KEY_WALKTHROUGH, value.walkthroughCompleted)
        }
        prefs.edit { putString(KEY_PAYLOAD, obj.toString()) }
    }

    private companion object {
        const val KEY_PAYLOAD = "settings"
        const val KEY_MODE = "mode"
        const val KEY_LINKED_PROVIDER = "linkedProvider"
        const val KEY_LINKED_MODEL = "linkedModel"
        const val KEY_WALKTHROUGH = "walkthroughCompleted"
    }
}
