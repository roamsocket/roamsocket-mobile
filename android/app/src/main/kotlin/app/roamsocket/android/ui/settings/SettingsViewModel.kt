package app.roamsocket.android.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Drives the Settings tab. Owns the API-key list, the GitHub PAT entry,
 * and the paired-server management. State is exposed as a single
 * [SettingsUiState] snapshot for the Compose screen to render.
 */
class SettingsViewModel(
    private val container: AppContainer,
) : ViewModel() {

    private val _state = MutableStateFlow(SettingsUiState())
    val state: StateFlow<SettingsUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            val providers = ProviderId.BUILT_IN.map { provider ->
                val hasKey = !container.secretStore.readApiKey(provider).isNullOrEmpty()
                ProviderEntry(provider, hasApiKey = hasKey)
            }
            val githubPat = !container.secretStore.readSecret(KEY_GITHUB_PAT).isNullOrEmpty()
            _state.value = _state.value.copy(
                providers = providers,
                hasGitHubPat = githubPat,
            )
        }
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

    private suspend fun refresh() {
        val providers = ProviderId.BUILT_IN.map { provider ->
            val hasKey = !container.secretStore.readApiKey(provider).isNullOrEmpty()
            ProviderEntry(provider, hasApiKey = hasKey)
        }
        val githubPat = !container.secretStore.readSecret(KEY_GITHUB_PAT).isNullOrEmpty()
        _state.value = _state.value.copy(
            providers = providers,
            hasGitHubPat = githubPat,
        )
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

data class SettingsUiState(
    val providers: List<ProviderEntry> = emptyList(),
    val hasGitHubPat: Boolean = false,
)

data class ProviderEntry(
    val provider: ProviderId,
    val hasApiKey: Boolean,
)
