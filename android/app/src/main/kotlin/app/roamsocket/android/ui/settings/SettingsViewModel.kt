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
 * prefix, the appearance, the voice provider, and the paired-server
 * management. State is exposed as a single [SettingsUiState] snapshot
 * for the Compose screen to render.
 */
class SettingsViewModel(
    private val container: AppContainer,
) : ViewModel() {

    private val _state = MutableStateFlow(SettingsUiState())
    val state: StateFlow<SettingsUiState> = _state.asStateFlow()

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
)

data class ProviderEntry(
    val provider: ProviderId,
    val hasApiKey: Boolean,
)
