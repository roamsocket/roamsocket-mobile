package app.roamsocket.android.ui.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
import app.roamsocket.core.providers.ModelCatalog
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Owns the live provider catalog: a list of `ModelCatalog.ProviderResult`
 * (provider + models + optional error), one entry per provider that has
 * an API key configured. The chat picker and the `selectModel` flow read
 * from this so the user sees the real provider catalog instead of the
 * hard-coded [ModelCatalog.defaults] list.
 *
 * Mirrors the iOS `AppState.providerResults` flow. The catalog is
 * fetched on first open and on demand after a provider or key change.
 */
class ModelCatalogViewModel(
    private val container: AppContainer,
) : ViewModel() {

    private val _state = MutableStateFlow(CatalogUiState())
    val state: StateFlow<CatalogUiState> = _state.asStateFlow()

    /**
     * Fetch the catalog for every provider that has a key. Replaces
     * the previous results on success. Safe to call repeatedly.
     */
    fun load(force: Boolean = false) {
        if (_state.value.isLoading) return
        if (!force && _state.value.results.isNotEmpty()) return
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, error = null)
            val keys = readAllKeys()
            val results = runCatching {
                ModelCatalog.fetchAll(keys, container.httpClient)
            }
            _state.value = if (results.isSuccess) {
                _state.value.copy(
                    isLoading = false,
                    results = results.getOrThrow(),
                    error = null,
                )
            } else {
                _state.value.copy(
                    isLoading = false,
                    error = results.exceptionOrNull()?.message ?: "Failed to load catalog",
                )
            }
        }
    }

    private suspend fun readAllKeys(): Map<ProviderId, String> {
        // Built-in providers (LocalMetal and Custom are skipped: iOS-only
        // or not built into the picker). The picker will further filter
        // out anything that returns zero models or an error.
        val providers = ProviderId.BUILT_IN
            .filter { it !is ProviderId.LocalMetal }
        val out = LinkedHashMap<ProviderId, String>()
        for (id in providers) {
            val key = container.secretStore.readApiKey(id)
            if (!key.isNullOrEmpty()) out[id] = key
        }
        return out
    }

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = (this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY] as RoamSocketApplication)
                ModelCatalogViewModel(app.container)
            }
        }
    }
}

/** UI-facing snapshot of the catalog. */
data class CatalogUiState(
    val isLoading: Boolean = false,
    val results: List<ModelCatalog.ProviderResult> = emptyList(),
    /** Set when the *whole* fetch failed (e.g. no network). */
    val error: String? = null,
)
