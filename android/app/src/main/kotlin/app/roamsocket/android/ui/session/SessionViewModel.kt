package app.roamsocket.android.ui.session

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
import app.roamsocket.core.protocol.ClientMessage
import app.roamsocket.core.protocol.ModelSelection
import app.roamsocket.core.protocol.PermissionDecision
import app.roamsocket.core.protocol.PermissionMode
import app.roamsocket.core.protocol.RepoRef
import app.roamsocket.core.protocol.ServerMessage
import app.roamsocket.core.server.Endpoint
import app.roamsocket.core.server.ServerClient
import app.roamsocket.core.server.Session
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * Drives one coding session against the desktop server. Connects the
 * WebSocket, sends `create_session`, then renders inbound protocol events
 * into a transcript the Compose screen shows.
 *
 * This is a focused port of `ios/.../SessionViewModel.swift` covering the
 * core loop only: session lifecycle, assistant deltas, tool calls, tool
 * results, diffs, permission prompts, and interrupt. Other features
 * (ports, tunnels, file browser, terminal) land in follow-up PRs.
 */
class SessionViewModel(
    private val container: AppContainer,
    private val config: SessionConfig,
    private val paired: PairedServerSnapshot,
    private val serverClient: ServerClient = ServerClient(),
) : ViewModel() {

    /** Snapshot of the persisted PairedServer, taken before ViewModel construction. */
    data class PairedServerSnapshot(
        val endpoint: String,
        val token: String,
        val serverName: String,
    )

    private val _state = MutableStateFlow(SessionUiState())
    val state: StateFlow<SessionUiState> = _state.asStateFlow()

    private var session: Session? = null
    private var streamJob: Job? = null

    init {
        connect()
    }

    fun send(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        val s = _state.value
        if (!s.isSessionReady) {
            // Queue for once the session is created.
            _state.update { it.copy(queuedMessage = trimmed, draft = "") }
            return
        }
        if (s.isRunning) {
            _state.update { it.copy(queuedMessage = trimmed, draft = "") }
            return
        }
        val sessionId = s.sessionId ?: return
        appendTranscript(TranscriptItem.User(trimmed))
        _state.update { it.copy(draft = "", isRunning = true) }
        try {
            session?.send(
                ClientMessage.UserMessage(sessionId = sessionId, text = trimmed)
            )
        } catch (t: Throwable) {
            _state.update { it.copy(isRunning = false, error = t.message ?: t.javaClass.simpleName) }
        }
    }

    fun updateDraft(text: String) {
        _state.update { it.copy(draft = text) }
    }

    fun respondPermission(allow: Boolean) {
        val pending = _state.value.pendingPermission ?: return
        val sessionId = _state.value.sessionId ?: return
        try {
            session?.send(
                ClientMessage.PermissionResponse(
                    sessionId = sessionId,
                    requestId = pending.id,
                    decision = if (allow) PermissionDecision.ALLOW else PermissionDecision.DENY,
                )
            )
        } catch (_: Throwable) {
            // Best effort; the server will time out the prompt anyway.
        }
        _state.update { it.copy(pendingPermission = null) }
    }

    fun interrupt() {
        val sessionId = _state.value.sessionId ?: return
        try {
            session?.send(ClientMessage.Interrupt(sessionId = sessionId))
        } catch (_: Throwable) {
            // ignored
        }
    }

    fun createPR() {
        val sessionId = _state.value.sessionId ?: return
        try {
            session?.send(
                ClientMessage.CreatePr(
                    sessionId = sessionId,
                    title = "Changes from RoamSocket",
                    body = "",
                )
            )
        } catch (_: Throwable) {
            // ignored
        }
    }

    fun disconnect() {
        streamJob?.cancel()
        session?.close()
        session = null
        _state.update { it.copy(isSessionReady = false, connectionStatusLine = "Disconnected") }
    }

    fun dismissError() {
        _state.update { it.copy(error = null) }
    }

    override fun onCleared() {
        super.onCleared()
        disconnect()
    }

    private fun connect() {
        val endpoint = Endpoint.fromHost(paired.endpoint)
        if (endpoint == null) {
            _state.update { it.copy(error = "Bad paired endpoint: ${paired.endpoint}") }
            return
        }
        _state.update { it.copy(connectionStatusLine = "Connecting…") }
        viewModelScope.launch {
            try {
                val s = serverClient.connect(endpoint = endpoint, token = paired.token)
                session = s
                _state.update { it.copy(connectionStatusLine = "Connected") }
                streamJob = launch {
                    s.incoming.collect { handleServerMessage(it) }
                }
                // Send create_session once connected.
                val repo = RepoRef(
                    fullName = config.repo.fullName,
                    baseBranch = config.repo.baseBranch,
                    workBranch = config.repo.workBranch,
                    githubToken = config.repo.githubToken,
                )
                val model = ModelSelection(
                    provider = config.model.provider.rawValue,
                    model = config.model.model,
                    effort = config.model.effort,
                    apiKey = config.model.apiKey,
                    baseUrl = config.model.baseUrl,
                    apiStyle = config.model.apiStyle,
                )
                s.send(
                    ClientMessage.CreateSession(
                        sessionId = null,
                        repo = repo,
                        environment = config.environment,
                        model = model,
                        permissionMode = config.permissionMode,
                        skills = config.skills,
                        mcpServers = emptyList(),
                    )
                )
            } catch (t: Throwable) {
                _state.update {
                    it.copy(
                        connectionStatusLine = "Disconnected",
                        error = t.message ?: t.javaClass.simpleName,
                    )
                }
            }
        }
    }

    private fun handleServerMessage(message: ServerMessage) {
        when (message) {
            is ServerMessage.SessionCreated -> onSessionCreated(message)
            is ServerMessage.AssistantDelta -> onAssistantDelta(message)
            is ServerMessage.ToolCall -> onToolCall(message)
            is ServerMessage.ToolResult -> onToolResult(message)
            is ServerMessage.Diff -> onDiff(message)
            is ServerMessage.PermissionRequest -> onPermissionRequest(message)
            is ServerMessage.SessionDone -> onSessionDone(message)
            is ServerMessage.PrCreated -> onPrCreated(message)
            is ServerMessage.Error -> onError(message)
            is ServerMessage.GitResult,
            is ServerMessage.SkillsSync,
            is ServerMessage.MCPSync,
            is ServerMessage.MemorySync,
            is ServerMessage.ConnectorStatusMsg,
            is ServerMessage.TerminalData,
            is ServerMessage.TerminalControl,
            is ServerMessage.FileListResult,
            is ServerMessage.FileReadResult,
            is ServerMessage.FileWriteResult,
            is ServerMessage.PortListResult,
            is ServerMessage.TunnelStatus,
            is ServerMessage.RemoteEndpoint,
            is ServerMessage.TaskList,
            is ServerMessage.GoalStatus,
            is ServerMessage.ModelStatus -> {
                // Surfaced in later PRs; ignore for now.
            }
        }
    }

    private fun onSessionCreated(m: ServerMessage.SessionCreated) {
        _state.update {
            it.copy(
                sessionId = m.sessionId,
                isSessionReady = true,
                connectionStatusLine = "Session ${m.sessionId.take(8)}…",
            )
        }
        // Flush queued message if any.
        val queued = _state.value.queuedMessage
        if (queued.isNotEmpty()) {
            _state.update { it.copy(queuedMessage = "") }
            send(queued)
        }
    }

    private fun onAssistantDelta(m: ServerMessage.AssistantDelta) {
        val current = _state.value.transcript.lastOrNull()
        if (current is TranscriptItem.Assistant) {
            // Coalesce consecutive deltas.
            val merged = current.copy(text = current.text + m.text)
            val newList = _state.value.transcript.dropLast(1) + merged
            _state.update { it.copy(transcript = newList, isRunning = true) }
        } else {
            appendTranscript(TranscriptItem.Assistant(m.text))
            _state.update { it.copy(isRunning = true) }
        }
    }

    private fun onToolCall(m: ServerMessage.ToolCall) {
        appendTranscript(
            TranscriptItem.Tool(
                id = m.callId,
                tool = m.tool,
                summary = m.summary,
                ok = null,
                output = null,
            )
        )
    }

    private fun onToolResult(m: ServerMessage.ToolResult) {
        // Update the matching tool item.
        val list = _state.value.transcript.map { item ->
            if (item is TranscriptItem.Tool && item.id == m.callId) {
                item.copy(ok = m.ok, output = m.output)
            } else item
        }
        _state.update { it.copy(transcript = list) }
    }

    private fun onDiff(m: ServerMessage.Diff) {
        appendTranscript(
            TranscriptItem.Diff(
                id = UUID.randomUUID().toString(),
                path = m.path,
                added = m.added,
                removed = m.removed,
            )
        )
    }

    private fun onPermissionRequest(m: ServerMessage.PermissionRequest) {
        _state.update {
            it.copy(
                pendingPermission = PendingPermission(
                    id = m.requestId,
                    tool = m.tool,
                    summary = m.summary,
                ),
            )
        }
    }

    private fun onSessionDone(m: ServerMessage.SessionDone) {
        val queued = _state.value.queuedMessage
        _state.update {
            it.copy(
                isRunning = false,
                connectionStatusLine = m.stopReason?.let { r -> "Done: $r" } ?: "Done",
                queuedMessage = "",
            )
        }
        if (queued.isNotEmpty()) {
            _state.update { it.copy() }
            send(queued)
        }
    }

    private fun onPrCreated(m: ServerMessage.PrCreated) {
        _state.update { it.copy(prUrl = m.url) }
    }

    private fun onError(m: ServerMessage.Error) {
        _state.update { it.copy(error = m.message) }
    }

    private fun appendTranscript(item: TranscriptItem) {
        _state.update { it.copy(transcript = it.transcript + item) }
    }

    companion object {
        fun factory(config: SessionConfig, paired: PairedServerSnapshot): ViewModelProvider.Factory =
            viewModelFactory {
                initializer {
                    val app = (this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY] as RoamSocketApplication)
                    SessionViewModel(app.container, config, paired)
                }
            }
    }
}

/** Compose-facing state snapshot. */
data class SessionUiState(
    val sessionId: String? = null,
    val isSessionReady: Boolean = false,
    val isRunning: Boolean = false,
    val connectionStatusLine: String? = "Connecting…",
    val transcript: List<TranscriptItem> = emptyList(),
    val draft: String = "",
    val queuedMessage: String = "",
    val pendingPermission: PendingPermission? = null,
    val prUrl: String? = null,
    val error: String? = null,
)

data class PendingPermission(
    val id: String,
    val tool: String,
    val summary: String,
)

/** One row in the session transcript. Sealed so the UI can pattern-match. */
sealed interface TranscriptItem {
    data class User(val text: String) : TranscriptItem
    data class Assistant(val text: String) : TranscriptItem
    data class Tool(
        val id: String,
        val tool: String,
        val summary: String,
        val ok: Boolean? = null,
        val output: String? = null,
    ) : TranscriptItem
    data class Diff(
        val id: String,
        val path: String,
        val added: Int,
        val removed: Int,
    ) : TranscriptItem
}
