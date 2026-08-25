package app.roamsocket.android.ui.environments

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import app.roamsocket.core.protocol.EnvironmentConfig
import app.roamsocket.core.protocol.NetworkAccess
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/**
 * Local-only persistence for cloud-environment configurations. Mirrors
 * `AppState.environments` + `AppState.selectedEnvironment` from
 * `ios/App/Sources/App/AppState.swift`.
 *
 * First launch seeds a single `Default` environment with
 * [NetworkAccess.TRUSTED] so the `SessionConfig.environment` field
 * always has a sensible value to forward to the desktop.
 *
 * Storage: SharedPreferences at `environments.v1` (same key the iOS
 * app uses, so a future cross-platform sync layer could share the
 * blob without renaming).
 */
class EnvironmentStore(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("environments.v1", Context.MODE_PRIVATE)

    private val _environments = MutableStateFlow<List<EnvironmentConfig>>(emptyList())
    val environments: StateFlow<List<EnvironmentConfig>> = _environments.asStateFlow()

    private val _selectedName = MutableStateFlow<String?>(null)

    init {
        load()
        if (_environments.value.isEmpty()) {
            val def = EnvironmentConfig(name = DEFAULT_NAME, networkAccess = NetworkAccess.TRUSTED)
            _environments.value = listOf(def)
            _selectedName.value = DEFAULT_NAME
            save()
        } else if (_selectedName.value == null) {
            _selectedName.value = _environments.value.first().name
            save()
        }
    }

    /** The currently-selected environment (or `null` if the list is empty). */
    val selected: EnvironmentConfig?
        get() = _environments.value.firstOrNull { it.name == _selectedName.value }
            ?: _environments.value.firstOrNull()

    fun environmentByName(name: String): EnvironmentConfig? =
        _environments.value.firstOrNull { it.name == name }

    /**
     * Insert or replace by name. If the new env replaces the currently
     * selected one, the selection moves with it.
     */
    fun addOrUpdate(env: EnvironmentConfig) {
        val trimmed = env.copy(name = env.name.trim())
        if (trimmed.name.isEmpty()) return
        val current = _environments.value.toMutableList()
        val idx = current.indexOfFirst { it.name == trimmed.name }
        if (idx >= 0) {
            current[idx] = trimmed
        } else {
            current.add(trimmed)
        }
        _environments.value = current
        if (_selectedName.value == null) _selectedName.value = trimmed.name
        save()
    }

    fun delete(name: String) {
        val current = _environments.value.toMutableList()
        val removed = current.removeAll { it.name == name }
        if (!removed) return
        _environments.value = current
        if (_selectedName.value == name) {
            _selectedName.value = current.firstOrNull()?.name
        }
        save()
    }

    fun select(name: String) {
        if (_environments.value.none { it.name == name }) return
        if (_selectedName.value == name) return
        _selectedName.value = name
        save()
    }

    // ------------------------------------------------------------------
    // Persistence
    // ------------------------------------------------------------------

    private fun save() {
        val envArray = JSONArray()
        for (env in _environments.value) {
            envArray.put(env.toJson())
        }
        prefs.edit {
            putString(KEY_ENVIRONMENTS, envArray.toString())
            putString(KEY_SELECTED, _selectedName.value)
        }
    }

    private fun load() {
        val raw = prefs.getString(KEY_ENVIRONMENTS, null)
        if (raw != null) {
            try {
                val array = JSONArray(raw)
                val list = mutableListOf<EnvironmentConfig>()
                for (i in 0 until array.length()) {
                    parseEnv(array.getJSONObject(i))?.let { list.add(it) }
                }
                _environments.value = list
            } catch (_: Throwable) {
                _environments.value = emptyList()
            }
        }
        _selectedName.value = prefs.getString(KEY_SELECTED, null)
    }

    private fun EnvironmentConfig.toJson(): JSONObject =
        JSONObject().apply {
            put(KEY_NAME, name)
            put(KEY_NETWORK_ACCESS, networkAccess.serialName)
            put(KEY_ALLOWED_DOMAINS, JSONArray(allowedDomains))
            put(KEY_VARIABLES, JSONObject(variables))
        }

    private fun parseEnv(obj: JSONObject): EnvironmentConfig? = try {
        val domainsArray = obj.optJSONArray(KEY_ALLOWED_DOMAINS) ?: JSONArray()
        val domains = mutableListOf<String>()
        for (i in 0 until domainsArray.length()) {
            domains.add(domainsArray.getString(i))
        }
        val varsObj = obj.optJSONObject(KEY_VARIABLES) ?: JSONObject()
        val variables = mutableMapOf<String, String>()
        for (key in varsObj.keys()) {
            variables[key] = varsObj.optString(key, "")
        }
        EnvironmentConfig(
            name = obj.getString(KEY_NAME),
            networkAccess = parseNetworkAccess(obj.optString(KEY_NETWORK_ACCESS, "trusted")),
            allowedDomains = domains,
            variables = variables,
        )
    } catch (_: Throwable) {
        null
    }

    private fun parseNetworkAccess(raw: String): NetworkAccess = when (raw.lowercase()) {
        "trusted" -> NetworkAccess.TRUSTED
        "limited" -> NetworkAccess.LIMITED
        "none" -> NetworkAccess.NONE
        "custom" -> NetworkAccess.CUSTOM
        else -> NetworkAccess.TRUSTED
    }

    private val NetworkAccess.serialName: String
        get() = when (this) {
            NetworkAccess.TRUSTED -> "trusted"
            NetworkAccess.LIMITED -> "limited"
            NetworkAccess.NONE -> "none"
            NetworkAccess.CUSTOM -> "custom"
        }

    companion object {
        const val DEFAULT_NAME: String = "Default"
        private const val KEY_ENVIRONMENTS = "environments"
        private const val KEY_SELECTED = "selected"
        private const val KEY_NAME = "name"
        private const val KEY_NETWORK_ACCESS = "networkAccess"
        private const val KEY_ALLOWED_DOMAINS = "allowedDomains"
        private const val KEY_VARIABLES = "variables"
    }
}
