package app.roamsocket.android.ui.code

import android.os.Build
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
import app.roamsocket.android.data.PairedServer
import app.roamsocket.android.data.PairedServerStore
import app.roamsocket.android.net.ServerDiscovery
import app.roamsocket.core.server.Endpoint
import app.roamsocket.core.server.ServerClient
import app.roamsocket.core.server.ServerClientException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.scan
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * Drives the Code tab. Discovers nearby desktop servers over NSD, lets
 * the user enter a pairing code, and persists the resulting bearer token
 * to [PairedServerStore] for later session use.
 */
class PairingViewModel(
    private val container: AppContainer,
    private val serverClient: ServerClient = ServerClient(),
    private val discovery: ServerDiscovery = ServerDiscovery(
        container.applicationContext,
    ),
    private val pairedStore: PairedServerStore = container.pairedServerStore,
) : ViewModel() {

    private val _state = MutableStateFlow(PairingUiState())
    val state: StateFlow<PairingUiState> = _state.asStateFlow()

    val paired: StateFlow<PairedServer?> = pairedStore.paired.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = null,
    )

    val nearbyEndpoints: StateFlow<List<Endpoint>> = discovery.observe()
        .scan(emptyList<Endpoint>()) { acc, ep ->
            val exists = acc.find { it.baseURL == ep.baseURL }
            if (exists != null) acc else acc + ep
        }
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5_000),
            initialValue = emptyList(),
        )

    fun setHostInput(input: String) {
        _state.value = _state.value.copy(hostInput = input)
    }

    fun setCodeInput(code: String) {
        // Strip whitespace + lowercase; the server is case-insensitive.
        val clean = code.filter { !it.isWhitespace() }.uppercase()
        _state.value = _state.value.copy(codeInput = clean)
    }

    fun pickEndpoint(endpoint: Endpoint) {
        _state.value = _state.value.copy(hostInput = endpoint.baseURL.removePrefix("http://"))
    }

    fun pair() {
        val s = _state.value
        val parsed = Endpoint.fromHost(s.hostInput)
        if (parsed == null) {
            _state.value = s.copy(error = "Invalid host. Try 192.168.1.10:4319.")
            return
        }
        if (s.codeInput.length != 6) {
            _state.value = s.copy(error = "Pairing code is 6 characters.")
            return
        }
        _state.value = s.copy(isPairing = true, error = null)
        viewModelScope.launch {
            try {
                val response = serverClient.pair(
                    endpoint = parsed,
                    code = s.codeInput,
                    deviceName = deviceName(),
                )
                pairedStore.save(
                    PairedServer(
                        endpoint = parsed.baseURL,
                        token = response.token,
                        serverName = response.serverName,
                        serverVersion = response.serverVersion,
                        publicUrl = response.publicUrl,
                    ),
                )
                _state.value = _state.value.copy(
                    isPairing = false,
                    codeInput = "",
                )
            } catch (e: ServerClientException.PairFailed) {
                _state.value = _state.value.copy(
                    isPairing = false,
                    error = e.message,
                )
            } catch (t: Throwable) {
                _state.value = _state.value.copy(
                    isPairing = false,
                    error = t.message ?: t.javaClass.simpleName,
                )
            }
        }
    }

    fun forget() {
        viewModelScope.launch { pairedStore.clear() }
    }

    fun dismissError() {
        _state.value = _state.value.copy(error = null)
    }

    private fun deviceName(): String {
        val manufacturer = Build.MANUFACTURER?.replaceFirstChar { it.uppercase() } ?: ""
        val model = Build.MODEL ?: ""
        return when {
            manufacturer.isEmpty() -> model.ifEmpty { "Android device" }
            model.startsWith(manufacturer, ignoreCase = true) -> model
            else -> "$manufacturer $model"
        }.ifEmpty { "Android device" }
    }

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = (this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY] as RoamSocketApplication)
                PairingViewModel(app.container)
            }
        }
    }
}

data class PairingUiState(
    val hostInput: String = "",
    val codeInput: String = "",
    val isPairing: Boolean = false,
    val error: String? = null,
)
