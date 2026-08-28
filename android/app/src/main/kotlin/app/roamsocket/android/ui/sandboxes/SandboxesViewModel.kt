package app.roamsocket.android.ui.sandboxes

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
import app.roamsocket.core.protocol.ClientMessage
import app.roamsocket.core.protocol.E2bRun
import app.roamsocket.core.protocol.E2bRunState
import app.roamsocket.core.protocol.ServerMessage
import app.roamsocket.core.protocol.TerminalStream
import app.roamsocket.core.server.Endpoint
import app.roamsocket.core.server.ServerClient
import app.roamsocket.core.server.Session
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * View-model for the Sandboxes screen. Owns a dedicated [Session] so the
 * user can keep streaming logs after the chat or code session has been
 * dismissed.
 */
class SandboxesViewModel(
    private val container: AppContainer,
) : ViewModel() {

    data class State(
        val isReady: Boolean = false,
        val runs: List<E2bRun> = emptyList(),
        val hasUserKey: Boolean = false,
        val lastError: String? = null,
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private val client = ServerClient()
    private var session: Session? = null
    private var collectJob: Job? = null

    fun start() {
        if (collectJob != null) return
        viewModelScope.launch {
            val pair = resolvePaired()
            if (pair == null) {
                _state.update { it.copy(lastError = "Not paired with a desktop server.") }
                return@launch
            }
            val (endpoint, token) = pair
            try {
                val s = client.connect(endpoint = endpoint, token = token)
                session = s
                _state.update { it.copy(isReady = true) }
                // Request the run history on connect.
                s.send(ClientMessage.E2bList(sessionId = null, limit = 50))
                collectJob = viewModelScope.launch {
                    s.incoming.collect { msg -> handle(msg) }
                }
            } catch (t: Throwable) {
                _state.update { it.copy(lastError = t.message ?: t.javaClass.simpleName) }
            }
        }
    }

    fun stop() {
        collectJob?.cancel()
        collectJob = null
        session?.close()
        session = null
        _state.update { it.copy(isReady = false) }
    }

    fun setKey(key: String) {
        viewModelScope.launch {
            try {
                session?.send(ClientMessage.E2bSetKey(apiKey = key))
            } catch (t: Throwable) {
                _state.update { it.copy(lastError = t.message ?: t.javaClass.simpleName) }
            }
        }
    }

    fun abort(runId: String) {
        viewModelScope.launch {
            try {
                session?.send(ClientMessage.E2bAbort(runId = runId))
            } catch (t: Throwable) {
                _state.update { it.copy(lastError = t.message ?: t.javaClass.simpleName) }
            }
        }
    }

    fun dismissError() {
        _state.update { it.copy(lastError = null) }
    }

    private fun handle(msg: ServerMessage) {
        when (msg) {
            is ServerMessage.E2bStarted -> upsert(msg.run)
            is ServerMessage.E2bStatus -> upsert(msg.run)
            is ServerMessage.E2bLog -> appendLog(msg.runId, msg.line)
            is ServerMessage.E2bList -> {
                _state.update {
                    it.copy(runs = msg.runs.sortedByDescending { run -> run.startedAt ?: 0L })
                }
            }
            is ServerMessage.E2bKeyAck -> {
                _state.update { it.copy(hasUserKey = msg.overrideActive) }
            }
            else -> Unit
        }
    }

    private fun upsert(run: E2bRun) {
        _state.update { s ->
            val next = s.runs.toMutableList()
            val idx = next.indexOfFirst { it.id == run.id }
            if (idx >= 0) next[idx] = run else next.add(0, run)
            s.copy(runs = next)
        }
    }

    /**
     * The server sends the full tail only on terminal `e2b_status`; while
     * the run is live we append log lines locally so the user can watch
     * the output grow. Mirrors the iOS store's behaviour.
     */
    private fun appendLog(runId: String, line: String) {
        if (line.isEmpty()) return
        _state.update { s ->
            val idx = s.runs.indexOfFirst { it.id == runId }
            if (idx < 0) return@update s
            val current = s.runs[idx]
            val tail = (current.outputTail + line).let {
                if (it.size > 5_000) it.takeLast(5_000) else it
            }
            s.copy(
                runs = s.runs.toMutableList().also {
                    it[idx] = current.copy(
                        status = if (current.status == E2bRunState.QUEUED) E2bRunState.RUNNING else current.status,
                        outputTail = tail,
                    )
                },
            )
        }
    }

    private suspend fun resolvePaired(): Pair<Endpoint, String>? {
        val p = container.pairedServerStore.paired.first() ?: return null
        val endpoint = Endpoint.fromHost(p.endpoint.removePrefix("http://")) ?: return null
        return endpoint to p.token
    }

    companion object {
        fun factoryFor(container: AppContainer): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { SandboxesViewModel(container) }
            }

        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = (this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY] as RoamSocketApplication)
                SandboxesViewModel(app.container)
            }
        }
    }
}
