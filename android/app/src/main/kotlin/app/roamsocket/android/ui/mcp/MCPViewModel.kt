/*
 * ViewModel for the MCP (connector) screen. Mirrors the iOS flow:
 * mirror the local MCPManager cache, optionally push a `mcp_sync`
 * request to the desktop on entry, and forward upsert/delete.
 */
package app.roamsocket.android.ui.mcp

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import app.roamsocket.android.AppContainer
import app.roamsocket.android.data.toEndpoint
import app.roamsocket.core.protocol.MCPServer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class MCPUiState(
    val servers: List<MCPServer> = emptyList(),
    val isLoading: Boolean = false,
    val lastSyncError: String? = null,
    val isPaired: Boolean = false,
) {
    val isEmpty: Boolean get() = servers.isEmpty()
}

class MCPViewModel(
    private val container: AppContainer,
) : ViewModel() {

    private val _uiState = MutableStateFlow(MCPUiState())
    val uiState: StateFlow<MCPUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            container.mcpManager.servers.collect { servers ->
                _uiState.update { it.copy(servers = servers) }
            }
        }
        viewModelScope.launch {
            container.pairedServerStore.paired.collect { pair ->
                _uiState.update { it.copy(isPaired = pair != null) }
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            val pair = container.pairedServerStore.current()
            _uiState.update { it.copy(isLoading = true) }
            if (pair != null) {
                val endpoint = pair.toEndpoint()
                if (endpoint != null) {
                    runCatching {
                        container.skillsMCPClient.requestMCPSync(endpoint, pair.token)
                    }.onFailure { err ->
                        _uiState.update { it.copy(lastSyncError = err.message) }
                    }
                }
            }
            _uiState.update { it.copy(isLoading = false) }
        }
    }

    fun toggleServer(id: String) {
        viewModelScope.launch { container.mcpManager.toggleServer(id) }
    }

    fun deleteServer(id: String) {
        viewModelScope.launch {
            val pair = container.pairedServerStore.current() ?: return@launch
            val endpoint = pair.toEndpoint() ?: return@launch
            runCatching {
                container.skillsMCPClient.deleteMCPServer(id, endpoint, pair.token)
            }.onFailure { err ->
                _uiState.update { it.copy(lastSyncError = err.message) }
            }
        }
    }

    fun addServer(
        name: String,
        description: String,
        command: String,
        args: List<String>,
        env: Map<String, String>,
    ) {
        viewModelScope.launch {
            val pair = container.pairedServerStore.current()
            if (pair == null) {
                _uiState.update { it.copy(lastSyncError = "Pair with a desktop to add MCP servers.") }
                return@launch
            }
            val endpoint = pair.toEndpoint()
            if (endpoint == null) {
                _uiState.update { it.copy(lastSyncError = "Bad endpoint") }
                return@launch
            }
            val server = MCPServer(
                id = "mcp-${System.currentTimeMillis().toString(36)}",
                name = name.trim().ifEmpty { "Untitled connector" },
                description = description.trim(),
                command = command.trim(),
                args = args,
                env = env,
                isEnabled = true,
            )
            runCatching {
                container.skillsMCPClient.upsertMCPServer(server, endpoint, pair.token)
            }.onFailure { err ->
                _uiState.update { it.copy(lastSyncError = err.message) }
            }
        }
    }

    fun dismissError() {
        _uiState.update { it.copy(lastSyncError = null) }
    }

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
                    return MCPViewModel(container) as T
                }
            }
    }
}
