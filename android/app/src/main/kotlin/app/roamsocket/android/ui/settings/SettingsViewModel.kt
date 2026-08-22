package app.roamsocket.android.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
import app.roamsocket.android.data.AppAppearance
import app.roamsocket.android.data.EffortLevel
import app.roamsocket.android.data.VoiceProvider
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Drives the Settings tab. Owns the API-key list, the GitHub PAT entry,
 * the always-expand-thinking toggle, the reasoning effort, the branch
 * prefix, the appearance, the voice provider, and the settings
 * push/pull sync to the user's GitHub repo.
 *
 * State is exposed as a single [SettingsUiState] snapshot for the Compose
 * screen to render. Sync activity (in-flight, message, per-kind
 * status, error) lives on the same snapshot so the sheet can show
 * progress inline without a second state stream.
 */
class SettingsViewModel(
    private val container: AppContainer,
) : ViewModel() {

    private val _state = MutableStateFlow(SettingsUiState())
    val state: StateFlow<SettingsUiState> = _state.asStateFlow()

    private val syncClient: SettingsSync = SettingsSync(container.httpClient)

    init {
        viewModelScope.launch { hydrate() }
    }

    /** Pull every persisted setting from DataStore + the secret store
     *  into [_state]. Safe to call any time; runs in [viewModelScope]. */
    private suspend fun hydrate() {
        val userSettings = container.userSettings
        _state.value = _state.value.copy(
            providers = ProviderId.BUILT_IN.map { provider ->
                ProviderEntry(
                    provider,
                    hasApiKey = !container.secretStore.readApiKey(provider).isNullOrEmpty(),
                )
            },
            hasGitHubPat = !container.secretStore.readSecret(KEY_GITHUB_PAT).isNullOrEmpty(),
            alwaysExpandThinking = userSettings.alwaysExpandThinking.first(),
            effort = userSettings.effort.first(),
            branchPrefix = userSettings.branchPrefix.first(),
            appearance = userSettings.appearance.first(),
            voiceProvider = userSettings.voiceProvider.first(),
            voiceOpenAIModel = userSettings.voiceOpenAIModel.first(),
        )
    }

    fun setApiKey(provider: ProviderId, key: String) {
        viewModelScope.launch {
            container.secretStore.writeApiKey(provider, key)
            refresh()
        }
    }

    fun setGitHubPat(pat: String) {
        viewModelScope.launch {
            container.secretStore.writeSecret(KEY_GITHUB_PAT, pat)
            refresh()
        }
    }

    fun clearGitHubPat() {
        viewModelScope.launch {
            container.secretStore.deleteSecret(KEY_GITHUB_PAT)
            refresh()
        }
    }

    fun forgetServer() {
        viewModelScope.launch { container.pairedServerStore.clear() }
    }

    fun setAlwaysExpandThinking(enabled: Boolean) {
        _state.value = _state.value.copy(alwaysExpandThinking = enabled)
        viewModelScope.launch { container.userSettings.setAlwaysExpandThinking(enabled) }
    }

    fun setEffort(level: EffortLevel) {
        _state.value = _state.value.copy(effort = level)
        viewModelScope.launch { container.userSettings.setEffort(level) }
    }

    fun setBranchPrefix(value: String) {
        _state.value = _state.value.copy(branchPrefix = value)
        viewModelScope.launch { container.userSettings.setBranchPrefix(value) }
    }

    fun setAppearance(appearance: AppAppearance) {
        _state.value = _state.value.copy(appearance = appearance)
        viewModelScope.launch { container.userSettings.setAppearance(appearance) }
    }

    fun setVoiceProvider(provider: VoiceProvider) {
        _state.value = _state.value.copy(voiceProvider = provider)
        viewModelScope.launch { container.userSettings.setVoiceProvider(provider) }
    }

    fun setVoiceOpenAIModel(model: String) {
        _state.value = _state.value.copy(voiceOpenAIModel = model)
        viewModelScope.launch { container.userSettings.setVoiceOpenAIModel(model) }
    }

    fun refresh() {
        viewModelScope.launch { hydrate() }
    }

    /**
     * Push the current settings snapshot to the user's private GitHub
     * repo. Creates the repo on first call. Updates the state
     * in-flight / message / error / per-kind status so the UI can
     * render progress.
     */
    fun pushSettings() {
        if (_state.value.syncInFlight) return
        viewModelScope.launch {
            val token = container.secretStore.readSecret(KEY_GITHUB_PAT)
            if (token.isNullOrEmpty()) {
                _state.value = _state.value.copy(
                    syncError = "Link a GitHub PAT in Account first.",
                )
                return@launch
            }
            _state.value = _state.value.copy(
                syncInFlight = true,
                syncError = null,
                syncMessage = null,
                syncStatuses = emptyMap(),
            )
            runCatching {
                val repo = syncClient.ensureRepo(token)
                val snapshot = buildSnapshot()
                syncClient.push(token, repo, snapshot)
                repo
            }.onSuccess { repo ->
                _state.value = _state.value.copy(
                    syncMessage = "Pushed settings to ${repo.fullName}.",
                    syncStatuses = mapOf("Settings" to "Pushed."),
                    syncInFlight = false,
                )
            }.onFailure { err ->
                _state.value = _state.value.copy(
                    syncError = err.message ?: err.javaClass.simpleName,
                    syncInFlight = false,
                )
            }
        }
    }

    /**
     * Pull the settings snapshot from the user's private GitHub repo
     * and apply it locally. Errors leave the state untouched so the
     * user can retry without losing their last good values.
     */
    fun pullSettings() {
        if (_state.value.syncInFlight) return
        viewModelScope.launch {
            val token = container.secretStore.readSecret(KEY_GITHUB_PAT)
            if (token.isNullOrEmpty()) {
                _state.value = _state.value.copy(
                    syncError = "Link a GitHub PAT in Account first.",
                )
                return@launch
            }
            _state.value = _state.value.copy(
                syncInFlight = true,
                syncError = null,
                syncMessage = null,
                syncStatuses = emptyMap(),
            )
            runCatching {
                val repo = syncClient.ensureRepo(token)
                val snap = syncClient.pull(token, repo)
                repo to snap
            }.onSuccess { (repo, snap) ->
                if (snap == null) {
                    _state.value = _state.value.copy(
                        syncMessage = "No settings.json yet in ${repo.fullName}.",
                        syncStatuses = mapOf("Settings" to "Not found in repo."),
                        syncInFlight = false,
                    )
                } else {
                    applySnapshot(snap)
                    _state.value = _state.value.copy(
                        syncMessage = "Pulled settings from ${repo.fullName}.",
                        syncStatuses = mapOf("Settings" to "Applied."),
                        syncInFlight = false,
                    )
                }
            }.onFailure { err ->
                _state.value = _state.value.copy(
                    syncError = err.message ?: err.javaClass.simpleName,
                    syncInFlight = false,
                )
            }
        }
    }

    /** Collect the live [SettingsUiState] into a [SettingsSyncSnapshot]. */
    private suspend fun buildSnapshot(): SettingsSyncSnapshot = SettingsSyncSnapshot(
        alwaysExpandThinking = container.userSettings.alwaysExpandThinking.first(),
        effort = container.userSettings.effort.first().raw,
        appearance = container.userSettings.appearance.first().raw,
        branchPrefix = container.userSettings.branchPrefix.first(),
        voiceProvider = container.userSettings.voiceProvider.first().raw,
        voiceOpenAIModel = container.userSettings.voiceOpenAIModel.first(),
        currentProvider = container.userSettings.currentProvider.first().rawValue,
        currentModel = container.userSettings.currentModel.first(),
        researchEnabled = container.userSettings.researchEnabled.first(),
        webSearchEnabled = container.userSettings.webSearchEnabled.first(),
        locationEnabled = container.userSettings.locationEnabled.first(),
        toolAccess = container.userSettings.toolAccess.first().raw,
        generatedAt = java.time.Instant.now().toString(),
    )

    /** Apply a pulled snapshot to UserSettings and refresh the state. */
    private suspend fun applySnapshot(snap: SettingsSyncSnapshot) {
        val u = container.userSettings
        u.setAlwaysExpandThinking(snap.alwaysExpandThinking)
        u.setEffort(EffortLevel.fromRaw(snap.effort))
        u.setAppearance(AppAppearance.fromRaw(snap.appearance))
        u.setBranchPrefix(snap.branchPrefix)
        u.setVoiceProvider(VoiceProvider.fromRaw(snap.voiceProvider))
        u.setVoiceOpenAIModel(snap.voiceOpenAIModel)
        val restoredProvider = ProviderId.fromRawValue(snap.currentProvider)
        if (restoredProvider != null) {
            u.setCurrent(restoredProvider, snap.currentModel)
        }
        u.setResearchEnabled(snap.researchEnabled)
        u.setWebSearchEnabled(snap.webSearchEnabled)
        u.setLocationEnabled(snap.locationEnabled)
        u.setToolAccess(app.roamsocket.android.data.ToolAccessLevel.fromRaw(snap.toolAccess))
        hydrate()
    }

    companion object {
        const val KEY_GITHUB_PAT: String = "github_pat"

        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = (this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY] as RoamSocketApplication)
                SettingsViewModel(app.container)
            }
        }
    }
}

/** Compose-facing state snapshot for the settings sheet. */
data class SettingsUiState(
    val providers: List<ProviderEntry> = emptyList(),
    val hasGitHubPat: Boolean = false,
    val alwaysExpandThinking: Boolean = false,
    val effort: EffortLevel = EffortLevel.High,
    val branchPrefix: String = "roamsocket",
    val appearance: AppAppearance = AppAppearance.System,
    val voiceProvider: VoiceProvider = VoiceProvider.FreeNeural,
    val voiceOpenAIModel: String = "tts-1",
    // GitHub sync state — surfaced in the Settings backup card.
    val syncInFlight: Boolean = false,
    val syncMessage: String? = null,
    val syncError: String? = null,
    val syncStatuses: Map<String, String> = emptyMap(),
)

data class ProviderEntry(
    val provider: ProviderId,
    val hasApiKey: Boolean,
)
