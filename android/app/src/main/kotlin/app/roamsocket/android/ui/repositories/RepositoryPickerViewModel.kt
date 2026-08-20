package app.roamsocket.android.ui.repositories

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
import app.roamsocket.android.ui.settings.SettingsViewModel.Companion.KEY_GITHUB_PAT
import app.roamsocket.core.github.GitHubClient
import app.roamsocket.core.github.GitHubRepo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Drives the "Choose repository" sheet on the Code tab. Mirrors the iOS
 * `RepositoryPickerSheet` view-model: pull the GitHub PAT from the
 * secret store, list the user's repos via the [GitHubClient], and let
 * the user pick one for the new coding session.
 */
class RepositoryPickerViewModel(
    private val container: AppContainer,
    private val client: GitHubClient = GitHubClient(),
) : ViewModel() {

    private val _state = MutableStateFlow(RepositoryPickerUiState())
    val state: StateFlow<RepositoryPickerUiState> = _state.asStateFlow()

    init {
        // Probe whether a PAT is set; if so, kick off the load.
        viewModelScope.launch {
            val hasPat = !container.secretStore.readSecret(KEY_GITHUB_PAT).isNullOrEmpty()
            _state.value = _state.value.copy(hasGitHubPat = hasPat)
            if (hasPat) load()
        }
    }

    /** Re-fetch the repo list (used when the user links a new PAT). */
    fun load(force: Boolean = false) {
        val current = _state.value
        if (!force && current.repos.isNotEmpty()) return
        viewModelScope.launch {
            val token = container.secretStore.readSecret(KEY_GITHUB_PAT)
            if (token.isNullOrEmpty()) {
                _state.value = current.copy(hasGitHubPat = false, isLoading = false)
                return@launch
            }
            _state.value = current.copy(isLoading = true, error = null, hasGitHubPat = true)
            try {
                val repos = client.listRepos(token = token)
                _state.value = _state.value.copy(
                    isLoading = false,
                    repos = repos,
                    error = null,
                )
            } catch (t: Throwable) {
                _state.value = _state.value.copy(
                    isLoading = false,
                    error = t.message ?: t.javaClass.simpleName,
                )
            }
        }
    }

    fun setQuery(query: String) {
        _state.value = _state.value.copy(query = query)
    }

    /**
     * Visible repos after the user's search filter. iOS does the same
     * case-insensitive substring match on `fullName`.
     */
    val filtered: List<GitHubRepo>
        get() {
            val q = _state.value.query.trim()
            if (q.isEmpty()) return _state.value.repos
            return _state.value.repos.filter { it.fullName.contains(q, ignoreCase = true) }
        }

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = (this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY] as RoamSocketApplication)
                RepositoryPickerViewModel(app.container)
            }
        }
    }
}

data class RepositoryPickerUiState(
    val hasGitHubPat: Boolean = false,
    val isLoading: Boolean = false,
    val repos: List<GitHubRepo> = emptyList(),
    val query: String = "",
    val error: String? = null,
)
