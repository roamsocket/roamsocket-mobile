/*
 * ViewModel for the Skills screen. Coordinates SkillManager (local
 * cache) + SkillsMCPClient (desktop sync) + MarketplaceStore
 * (catalog fetch).
 *
 * Mirrors iOS `SkillsViewModel` (the wiring used to live inside the
 * `AppState` ObservableObject there).
 */
package app.roamsocket.android.ui.skills

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import app.roamsocket.android.AppContainer
import app.roamsocket.android.data.toEndpoint
import app.roamsocket.core.marketplace.MarketplaceSkillListing
import app.roamsocket.core.protocol.Skill
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** UI state for the Skills screen. */
data class SkillsUiState(
    val installed: List<Skill> = emptyList(),
    val marketplace: List<MarketplaceSkillListing> = emptyList(),
    val isLoading: Boolean = false,
    val isMarketplaceLoading: Boolean = false,
    val lastSyncError: String? = null,
    val isPaired: Boolean = false,
) {
    val isEmpty: Boolean get() = installed.isEmpty() && marketplace.isEmpty()
}

class SkillsViewModel(
    private val container: AppContainer,
) : ViewModel() {

    private val _uiState = MutableStateFlow(SkillsUiState())
    val uiState: StateFlow<SkillsUiState> = _uiState.asStateFlow()

    init {
        // Mirror the manager flows into the UI state.
        viewModelScope.launch {
            container.skillManager.installedSkills.collect { skills ->
                _uiState.update { it.copy(installed = skills) }
            }
        }
        viewModelScope.launch {
            container.marketplaceStore.state.collect { st ->
                _uiState.update {
                    it.copy(
                        marketplace = st.catalog.skills,
                    )
                }
            }
        }
        // Resolve paired server (used for the empty-state copy + the
        // sync CTA). `pairedServerStore.paired` exposes the current
        // endpoint / token if any.
        viewModelScope.launch {
            container.pairedServerStore.paired.collect { pair ->
                _uiState.update { it.copy(isPaired = pair != null) }
            }
        }
    }

    /** Pull a fresh list of skills from the desktop and refresh the
     *  marketplace catalog in parallel. No-op if not paired. */
    fun refresh() {
        viewModelScope.launch {
            val pair = container.pairedServerStore.current()
            _uiState.update { it.copy(isLoading = true) }
            if (pair == null) {
                // Still try to refresh the marketplace even when not
                // paired — the catalog is public HTTPS.
                runCatching { container.marketplaceStore.refresh() }
                _uiState.update { it.copy(isLoading = false) }
                return@launch
            }
            val endpoint = pair.toEndpoint()
            if (endpoint == null) {
                _uiState.update { it.copy(isLoading = false) }
                return@launch
            }
            runCatching {
                container.skillsMCPClient.requestSkillsSync(endpoint, pair.token)
            }.onFailure { err ->
                _uiState.update { it.copy(lastSyncError = err.message) }
            }
            runCatching { container.marketplaceStore.refresh() }
            _uiState.update { it.copy(isLoading = false) }
        }
    }

    fun toggleSkill(id: String) {
        viewModelScope.launch { container.skillManager.toggleSkill(id) }
    }

    fun deleteSkill(id: String) {
        viewModelScope.launch {
            val pair = container.pairedServerStore.current() ?: return@launch
            val endpoint = pair.toEndpoint() ?: return@launch
            runCatching {
                container.skillManager.toggleSkill(id) // optimistic off
                container.skillsMCPClient.deleteSkill(id, endpoint, pair.token)
            }.onFailure { err ->
                _uiState.update { it.copy(lastSyncError = err.message) }
            }
        }
    }

    /** Install (or re-install) a marketplace skill. Pushes the
     *  listing to the desktop which writes it to the user's skills
     *  git repo and replies with a fresh `skills_sync`. */
    fun installFromMarketplace(listing: MarketplaceSkillListing) {
        viewModelScope.launch {
            val pair = container.pairedServerStore.current()
            if (pair == null) {
                _uiState.update { it.copy(lastSyncError = "Pair with a desktop to install skills.") }
                return@launch
            }
            val endpoint = pair.toEndpoint()
            if (endpoint == null) {
                _uiState.update { it.copy(lastSyncError = "Bad endpoint") }
                return@launch
            }
            val skill = Skill(
                id = listing.id,
                name = listing.name,
                description = listing.description,
                content = listing.skillContent,
                category = listing.category ?: "Other",
                source = when (listing.source?.lowercase()) {
                    "official" -> app.roamsocket.core.protocol.SkillSource.OFFICIAL
                    "custom" -> app.roamsocket.core.protocol.SkillSource.CUSTOM
                    else -> app.roamsocket.core.protocol.SkillSource.COMMUNITY
                },
                isEnabled = true,
                frontmatter = mapOf(
                    "name" to listing.name,
                    "description" to listing.description,
                ),
            )
            runCatching {
                container.skillsMCPClient.upsertSkill(skill, endpoint, pair.token)
            }.onFailure { err ->
                _uiState.update { it.copy(lastSyncError = err.message) }
            }
        }
    }

    /** Save a brand-new custom text skill and push it to the desktop. */
    fun saveCustomSkill(name: String, description: String, content: String) {
        viewModelScope.launch {
            val pair = container.pairedServerStore.current()
            if (pair == null) {
                _uiState.update { it.copy(lastSyncError = "Pair with a desktop to add skills.") }
                return@launch
            }
            val endpoint = pair.toEndpoint()
            if (endpoint == null) {
                _uiState.update { it.copy(lastSyncError = "Bad endpoint") }
                return@launch
            }
            val skill = Skill(
                id = "custom-${System.currentTimeMillis().toString(36)}",
                name = name.trim().ifEmpty { "Untitled skill" },
                description = description.trim(),
                content = content,
                category = "Custom",
                source = app.roamsocket.core.protocol.SkillSource.CUSTOM,
                isEnabled = true,
                frontmatter = mapOf(
                    "name" to name.trim(),
                    "description" to description.trim(),
                ),
            )
            runCatching {
                container.skillsMCPClient.upsertSkill(skill, endpoint, pair.token)
            }.onFailure { err ->
                _uiState.update { it.copy(lastSyncError = err.message) }
            }
        }
    }

    fun dismissError() {
        _uiState.update { it.copy(lastSyncError = null) }
    }

    /** Bootstrap the local cache so the UI shows something before
     *  the first `refresh()` resolves. Safe to call repeatedly. */
    fun preload() {
        viewModelScope.launch {
            runCatching { container.preloadSkillsAndMCP() }
        }
    }

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T {
                    return SkillsViewModel(container) as T
                }
            }
    }
}
