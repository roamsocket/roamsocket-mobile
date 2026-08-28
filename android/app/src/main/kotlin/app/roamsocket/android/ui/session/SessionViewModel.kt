package app.roamsocket.android.ui.session

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
import app.roamsocket.core.code.CodeSession
import app.roamsocket.core.code.CodeSessionRepository
import app.roamsocket.core.code.SessionTranscriptLine
import app.roamsocket.core.protocol.AgentTaskStatus
import app.roamsocket.core.protocol.ClientMessage
import app.roamsocket.core.protocol.GoalState
import app.roamsocket.core.protocol.ModelSelection
import app.roamsocket.core.protocol.ModelState
import app.roamsocket.core.protocol.PermissionDecision
import app.roamsocket.core.protocol.PermissionMode
import app.roamsocket.core.protocol.RepoRef
import app.roamsocket.core.protocol.ServerMessage
import app.roamsocket.core.protocol.TranscriptEvent
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
    private val codeSessionRepository: CodeSessionRepository = container.codeSessionRepository,
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
        // Register (or restore) the CodeSession row so the sidebar
        // shows the in-flight session. Re-opening an existing session
        // (config.id already exists in the store) reuses the same row.
        registerCodeSession()
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

    /**
     * Replace the paired endpoint/token (called from the re-pair sheet on
     * success) and immediately retry the connection. Mirrors the
     * `tokenWhenPairingPresented` → `model.retryConnection()` flow in
     * iOS `SessionView`.
     */
    fun applyRePair(endpoint: String, token: String, serverName: String) {
        // Mutate the snapshot by reassigning through reflection-style —
        // since `paired` is a `val`, we set a new private snapshot and
        // retry. The simplest approach: tear down the old stream and
        // reconnect with the new values.
        reconnectWith(endpoint = endpoint, token = token, serverName = serverName)
    }

    /**
     * Internal helper: swap the snapshot and reconnect. The public
     * surface is [applyRePair] which the SessionScreen calls when the
     * pairing sheet returns a successful [PairedServer].
     */
    private fun reconnectWith(endpoint: String, token: String, serverName: String) {
        // `paired` is a val, so we use a small trick: cancel the stream
        // job, then call the (private) connect() — but `connect` reads
        // from `paired`. We have to mutate via reflection.
        // Easier: just track the new values in a separate field.
        reconnectOverride = PairedServerSnapshot(
            endpoint = endpoint,
            token = token,
            serverName = serverName,
        )
        streamJob?.cancel()
        runCatching { session?.close() }
        session = null
        connect()
    }

    /**
     * Transient override set by [reconnectWith]. When non-null, [connect]
     * uses this snapshot instead of the constructor [paired] field. The
     * outer closure can re-assign `paired` via this hook without the
     * `val` constraint.
     */
    private var reconnectOverride: PairedServerSnapshot? = null

    private fun failNeedsRePair(detail: String) {
        _state.update {
            it.copy(
                connectionStatusLine = "Re-pair required",
                error = detail,
                needsRePair = true,
            )
        }
        // Also mark the persisted session as NeedsInput so the sidebar
        // surfaces a CTA.
        val id = _state.value.persistedSessionId
        if (id != null) {
            codeSessionRepository.update(id) {
                it.copy(status = CodeSession.Status.NEEDS_INPUT, updatedAtMillis = System.currentTimeMillis())
            }
        }
    }

    private fun isUnauthorizedError(detail: String): Boolean {
        val lower = detail.lowercase()
        return lower.contains("unauthorized") ||
            lower.contains("re-pair") ||
            lower.contains("re-pair") ||
            lower.contains("token expired") ||
            lower.contains("token invalid") ||
            lower.contains("invalid token")
    }

    /**
     * Reconnect using [paired] or the [reconnectOverride] when present.
     * Centralised so the re-pair flow and the cold-start both use the
     * same code path.
     */
    private fun connect() {
        val snapshot = reconnectOverride ?: paired
        val endpoint = Endpoint.fromHost(snapshot.endpoint)
        if (endpoint == null) {
            _state.update { it.copy(error = "Bad paired endpoint: ${snapshot.endpoint}") }
            return
        }
        if (snapshot.token.isBlank()) {
            failNeedsRePair("Pair a desktop server first.")
            return
        }
        _state.update { it.copy(connectionStatusLine = "Connecting…", needsRePair = false) }
        viewModelScope.launch {
            try {
                val s = serverClient.connect(endpoint = endpoint, token = snapshot.token)
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
                val msg = t.message ?: t.javaClass.simpleName
                if (isUnauthorizedError(msg)) {
                    failNeedsRePair(msg)
                } else {
                    _state.update {
                        it.copy(
                            connectionStatusLine = "Disconnected",
                            error = msg,
                        )
                    }
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
            is ServerMessage.TaskList -> onTaskList(message)
            is ServerMessage.GoalStatus -> onGoalStatus(message)
            is ServerMessage.ModelStatus -> onModelStatus(message)
            is ServerMessage.TranscriptReplay -> onTranscriptReplay(message)
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
            is ServerMessage.E2bStarted,
            is ServerMessage.E2bLog,
            is ServerMessage.E2bStatus,
            is ServerMessage.E2bList,
            is ServerMessage.E2bKeyAck -> {
                // Surfaced in later PRs (or handled at the app-level Sandboxes
                // coordinator). Keep the SessionViewModel's `when` exhaustive
                // without doing duplicate work here.
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
            setAgentRunning(true)
            scheduleTranscriptSave()
        } else {
            appendTranscript(TranscriptItem.Assistant(m.text))
            _state.update { it.copy(isRunning = true) }
            setAgentRunning(true)
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

    /**
     * Server replayed the rolling transcript because the phone's socket
     * dropped while the agent kept running on the desktop. Mirrors
     * `ios/.../SessionViewModel.handle(...)` case `.transcriptReplay`:
     * replace the locally-cached items with the authoritative server
     * view, then resume streaming live events on the same connection.
     * `isLive` drives the "Working" indicator; `truncated` is surfaced
     * as a notice so the user knows earlier events are gone.
     */
    private fun onTranscriptReplay(m: ServerMessage.TranscriptReplay) {
        val rebuilt = rebuildItemsFromReplay(m.events)
        _state.update {
            it.copy(
                transcript = rebuilt,
                isRunning = m.isLive,
            )
        }
        setAgentRunning(m.isLive)
        val suffix = if (m.truncated) " (earlier events trimmed)" else ""
        appendNotice("Synced ${m.events.size} events from desktop$suffix.")
        scheduleTranscriptSave()
    }

    /**
     * Mirror the live `handleServerMessage` semantics: assistant deltas
     * coalesce into a single rolling row, tool results update the
     * matching call, diffs append verbatim. SessionDone is intentionally
     * ignored here — the `isLive` flag on the replay drives running
     * state instead. Mirrors `ios/.../SessionViewModel.rebuildItems(...)`.
     */
    private fun rebuildItemsFromReplay(events: List<TranscriptEvent>): List<TranscriptItem> {
        val out = mutableListOf<TranscriptItem>()
        for (event in events) {
            when (event) {
                is TranscriptEvent.User -> {
                    out += TranscriptItem.User(event.text)
                }
                is TranscriptEvent.AssistantDelta -> {
                    val last = out.lastOrNull()
                    if (last is TranscriptItem.Assistant) {
                        out[out.size - 1] = last.copy(text = last.text + event.text)
                    } else {
                        out += TranscriptItem.Assistant(event.text)
                    }
                }
                is TranscriptEvent.ToolCall -> {
                    out += TranscriptItem.Tool(
                        id = event.callId,
                        tool = event.tool,
                        summary = event.summary,
                    )
                }
                is TranscriptEvent.ToolResult -> {
                    val idx = out.indexOfLast { it is TranscriptItem.Tool && it.id == event.callId }
                    if (idx >= 0) {
                        val current = out[idx] as TranscriptItem.Tool
                        out[idx] = current.copy(ok = event.ok, output = event.output)
                    }
                }
                is TranscriptEvent.Diff -> {
                    out += TranscriptItem.Diff(
                        id = UUID.randomUUID().toString(),
                        path = event.path,
                        added = event.added,
                        removed = event.removed,
                    )
                }
            }
        }
        return out
    }

    /**
     * Append a low-emphasis informational line to the transcript
     * (e.g. a reattach notice). The firstUserMessage tracker ignores
     * notices, so they never poison the auto-commit subject.
     */
    private fun appendNotice(text: String) {
        appendTranscript(TranscriptItem.Notice(text))
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
        setAgentRunning(false)
        scheduleTranscriptSave()
        if (queued.isNotEmpty()) {
            _state.update { it.copy() }
            send(queued)
        }
    }

    private fun onPrCreated(m: ServerMessage.PrCreated) {
        _state.update { it.copy(prUrl = m.url) }
        val id = _state.value.persistedSessionId
        if (id != null) {
            codeSessionRepository.update(id) {
                it.copy(
                    prURL = m.url,
                    status = CodeSession.Status.READY_FOR_REVIEW,
                    updatedAtMillis = System.currentTimeMillis(),
                )
            }
        }
    }

    private fun onError(m: ServerMessage.Error) {
        _state.update { it.copy(error = m.message) }
    }

    private fun onTaskList(m: ServerMessage.TaskList) {
        // The desktop server pushes the live checklist via
        // `update_tasks` (the agent's `update_plan` tool). Mirror
        // straight into state — the session screen renders the
        // progress as a banner under the top bar.
        _state.update { it.copy(agentTasks = m.tasks) }
    }

    private fun onGoalStatus(m: ServerMessage.GoalStatus) {
        _state.update {
            it.copy(
                goalStatus = GoalStatusUi(
                    state = m.status,
                    condition = m.condition,
                    reason = m.reason,
                    message = m.message,
                ),
            )
        }
    }

    private fun onModelStatus(m: ServerMessage.ModelStatus) {
        // Local-model loaders (MLX / Metal) push a status frame
        // before/while the agent runs. We surface this as a thin
        // banner so the user isn't staring at a silent "Connecting…"
        // line while a multi-GB model warms up.
        _state.update {
            it.copy(
                modelStatus = ModelStatusUi(
                    state = m.status,
                    message = m.message,
                    hubId = m.hubId,
                ),
            )
        }
    }

    private fun appendTranscript(item: TranscriptItem) {
        _state.update { it.copy(transcript = it.transcript + item) }
        scheduleTranscriptSave()
        // Track tool count + first user message for the auto commit subject.
        if (item is TranscriptItem.User && _state.value.firstUserMessage == null) {
            _state.update { it.copy(firstUserMessage = item.text) }
        }
    }

    /**
     * Hook the live assistant / tool / diff into the persisted CodeSession
     * row. Re-opening an existing session (id already in the store) reuses
     * the same row and hydrates the transcript.
     */
    private fun registerCodeSession() {
        val existing = codeSessionRepository.session(config.id)
        if (existing != null) {
            _state.update {
                it.copy(
                    persistedSessionId = existing.id,
                    firstUserMessage = existing.transcript
                        .firstOrNull { it.kind == SessionTranscriptLine.Kind.USER }
                        ?.text,
                )
            }
            // Hydrate the live transcript from the persisted lines.
            val items = existing.transcript.mapNotNull { line ->
                when (line.kind) {
                    SessionTranscriptLine.Kind.USER -> TranscriptItem.User(line.text)
                    SessionTranscriptLine.Kind.ASSISTANT -> if (line.text.isNotEmpty()) TranscriptItem.Assistant(line.text) else null
                    SessionTranscriptLine.Kind.TOOL -> TranscriptItem.Tool(
                        id = line.id.removePrefix("t-"),
                        tool = line.tool.orEmpty(),
                        summary = line.text,
                        ok = line.ok,
                    )
                    SessionTranscriptLine.Kind.DIFF -> TranscriptItem.Diff(
                        id = line.id.removePrefix("d-"),
                        path = line.path.orEmpty(),
                        added = line.added ?: 0,
                        removed = line.removed ?: 0,
                    )
                    // Notices survive the round-trip so a reattach notice
                    // written before app close is still shown on resume.
                    SessionTranscriptLine.Kind.NOTICE -> TranscriptItem.Notice(line.text)
                }
            }
            if (items.isNotEmpty()) {
                _state.update { it.copy(transcript = items) }
            }
            codeSessionRepository.setAgentActive(existing.id, true)
            return
        }
        val now = System.currentTimeMillis()
        val session = CodeSession(
            id = config.id,
            title = config.repo.fullName,
            repoFullName = config.repo.fullName,
            baseBranch = config.repo.baseBranch.orEmpty(),
            workBranch = config.repo.workBranch,
            status = CodeSession.Status.WORKING,
            createdAtMillis = now,
            updatedAtMillis = now,
            wireSessionId = "s_${config.id.take(8).lowercase()}",
            environment = config.environment,
        )
        codeSessionRepository.add(session)
        _state.update { it.copy(persistedSessionId = session.id) }
    }

    /**
     * Persist the live transcript onto the Code session row. Mirrors
     * iOS `SessionViewModel.scheduleTranscriptSave` (400 ms debounce).
     */
    private var saveJob: Job? = null
    private fun scheduleTranscriptSave() {
        saveJob?.cancel()
        val id = _state.value.persistedSessionId ?: return
        val snapshot = _state.value.transcript.map { it.toPersisted() }
        saveJob = viewModelScope.launch {
            kotlinx.coroutines.delay(400)
            codeSessionRepository.saveTranscript(id, snapshot)
        }
    }

    /**
     * Toggle the per-session mid-turn flag (drives the `Working` status
     * in the sidebar without shuffling the sort). Called by the
     * transcript handlers whenever a turn starts or ends.
     */
    private fun setAgentRunning(active: Boolean) {
        val id = _state.value.persistedSessionId ?: return
        codeSessionRepository.setAgentActive(id, active)
    }

    /**
     * Send a [ClientMessage.GitPublish] with the supplied action bitmask
     * and message. The server replies with `git_result`; the UI updates
     * its status row from the result.
     */
    fun gitPublish(
        message: String,
        commit: Boolean,
        push: Boolean,
        openPr: Boolean,
    ) {
        val sessionId = _state.value.sessionId ?: return
        val msg = if (commit) message else ""
        runCatching {
            session?.send(
                ClientMessage.GitPublish(
                    sessionId = sessionId,
                    message = msg,
                    commit = commit,
                    push = push,
                    openPr = openPr,
                ),
            )
        }
    }

    /**
     * One-tap `Finish · PR` (mirrors iOS `finishWithPR`): stages,
     * commits, pushes, and opens the PR in a single call. The commit
     * subject is generated by [CommitMessageGenerator] from the live
     * transcript / diff stats.
     */
    fun finishWithPR() {
        val s = _state.value
        val subject = CommitMessageGenerator.suggest(
            firstUserMessage = s.firstUserMessage,
            diffSummary = null,
            transcript = s.transcript.map { it.toPersisted() },
            diffStats = s.totalDiffStats,
        )
        gitPublish(message = subject, commit = true, push = true, openPr = true)
    }

    /**
     * Request a fresh `port_list` from the desktop and cache the
     * result in state. Returns the [Job] so callers can `join()`
     * before reading `state.openPorts`. Called by the Browser menu
     * auto-preview flow.
     */
    fun refreshPorts(): Job? {
        val sessionId = _state.value.sessionId ?: return null
        val endpoint = Endpoint.fromHost((reconnectOverride ?: paired).endpoint) ?: return null
        val token = (reconnectOverride ?: paired).token
        if (token.isEmpty()) return null
        return viewModelScope.launch {
            val list = runCatching {
                app.roamsocket.core.server.WorkspaceRpc.withConnection(
                    endpoint = endpoint,
                    token = token,
                    send = { session -> session.send(ClientMessage.PortList(sessionId)) },
                    match = { msg ->
                        when (msg) {
                            is ServerMessage.PortListResult -> msg.ports
                            else -> null
                        }
                    },
                )
            }.getOrDefault(emptyList())
            _state.update { it.copy(openPorts = list) }
        }
    }

    /**
     * Pick the first web-shaped port (vite / next / uvicorn / etc.) and
     * call `tunnel_start` to get a public URL. The caller opens it in
     * the system browser. Mirrors iOS `SessionViewModel.exposePortForPreview`.
     */
    suspend fun exposePortForPreview(port: Int): String? {
        val endpoint = Endpoint.fromHost((reconnectOverride ?: paired).endpoint) ?: return null
        val token = (reconnectOverride ?: paired).token
        val sessionId = _state.value.sessionId ?: return null
        if (token.isEmpty()) return null
        return runCatching {
            app.roamsocket.core.server.WorkspaceRpc.withConnection(
                endpoint = endpoint,
                token = token,
                timeoutSeconds = 25,
                send = { session ->
                    session.send(
                        ClientMessage.TunnelStart(
                            sessionId = sessionId,
                            port = port,
                            provider = app.roamsocket.core.protocol.TunnelProvider.AUTO,
                        ),
                    )
                },
                match = { msg ->
                    when (msg) {
                        is ServerMessage.TunnelStatus -> msg.tunnels
                        else -> null
                    }
                },
            ).firstOrNull { it.port == port }?.url
        }.getOrNull()
    }

    /**
     * Auto browser preview (mirrors iOS `openBrowserPreview` in
     * `SessionView`): refresh ports, pick the first web-shaped one,
     * start a tunnel, hand the public URL to [onUrl]. The
     * `isBrowserBusy` flag drives the disabled state of the menu
     * item so a second tap doesn't fire while the tunnel is being
     * set up.
     */
    fun openBrowserPreview(onUrl: (String?) -> Unit) {
        if (_state.value.isBrowserBusy) return
        _state.update { it.copy(isBrowserBusy = true) }
        viewModelScope.launch {
            try {
                refreshPorts()?.join() // suspend until the port list is in state
                val port = _state.value.primaryWebPort
                val url = if (port != null) exposePortForPreview(port) else null
                _state.update { it.copy(isBrowserBusy = false) }
                onUrl(url)
            } catch (t: Throwable) {
                _state.update { it.copy(isBrowserBusy = false) }
                onUrl(null)
            }
        }
    }

    /**
     * Prepare a one-line commit subject via [CommitMessageGenerator]. The
     * iOS port asks Apple Foundation Models for a suggestion; on Android
     * the heuristic alone is good enough for the collapsed card label.
     */
    fun suggestCommitMessage(): String {
        val s = _state.value
        return CommitMessageGenerator.suggest(
            firstUserMessage = s.firstUserMessage,
            diffSummary = null,
            transcript = s.transcript.map { it.toPersisted() },
            diffStats = s.totalDiffStats,
        )
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
    /** Live checklist from the agent's `update_plan` tool. Empty until the
     *  first `task_list` frame arrives. */
    val agentTasks: List<app.roamsocket.core.protocol.AgentTaskItem> = emptyList(),
    /** Active `/goal` condition for this coding session (banner). */
    val goalStatus: GoalStatusUi? = null,
    /** Live local-model loading state for this coding session (banner). */
    val modelStatus: ModelStatusUi? = null,
    /**
     * True when the live session saw an unauthorized / no-token condition
     * and the user must re-pair to continue. Mirrors iOS
     * `SessionViewModel.needsRePair`.
     */
    val needsRePair: Boolean = false,
    /** Latest persisted CodeSession id so callers can update the same row. */
    val persistedSessionId: String? = null,
    /** First user message — used as the seed for the auto commit subject. */
    val firstUserMessage: String? = null,
    /**
     * Cached list of listening ports reported by the desktop (refreshed
     * by the workspace menu's "Browser" entry). Empty until the first
     * [SessionViewModel.refreshPorts] call lands.
     */
    val openPorts: List<app.roamsocket.core.protocol.ListeningPort> = emptyList(),
    /** True while the auto-browser-preview tunnel is being created. */
    val isBrowserBusy: Boolean = false,
) {
    /** Combined +/- across every `Diff` row the agent has produced. */
    val totalDiffStats: DiffStats
        get() = transcript.fold(DiffStats()) { acc, item ->
            if (item is TranscriptItem.Diff) acc.copy(
                added = acc.added + item.added,
                removed = acc.removed + item.removed,
            ) else acc
        }

    val hasDiffs: Boolean get() = transcript.any { it is TranscriptItem.Diff }

    /** True when the agent has any checklist rows (drives the
     *  `X/Y` chip in the top bar + the progress banner). */
    val hasAgentTasks: Boolean get() = agentTasks.isNotEmpty()

    val taskProgress: TaskProgress
        get() {
            val total = agentTasks.size
            val done = agentTasks.count { it.status == AgentTaskStatus.COMPLETED }
            return TaskProgress(done = done, total = total)
        }

    /** True when the live `/goal` banner should be shown. Mirrors
     *  iOS `model.showsGoalBanner`. */
    val showsGoalBanner: Boolean
        get() {
            val goal = goalStatus ?: return false
            return goal.state == GoalState.ACTIVE || goal.state == GoalState.ACHIEVED
        }

    val hasActiveGoal: Boolean get() = goalStatus?.state == GoalState.ACTIVE

    /**
     * Best guess at the project's web server port. Mirrors iOS
     * `SessionViewModel.pickWebPort(from:)`: tries the conventional
     * dev-server ports first, then a heuristic on the command name,
     * then the first port the desktop reports.
     */
    val primaryWebPort: Int?
        get() {
            val preferred = listOf(3000, 5173, 5174, 4173, 8080, 8000, 4200, 5000, 4321, 1234, 3001, 8081)
            val ports = openPorts
            preferred.firstOrNull { p -> ports.any { it.port == p } }?.let { return it }
            val heuristics = listOf("node", "vite", "next", "webpack", "python", "uvicorn", "ruby", "php", "deno", "bun")
            for (entry in ports) {
                val lower = entry.command.lowercase()
                if (heuristics.any { lower.contains(it) }) return entry.port
            }
            return ports.firstOrNull()?.port
        }
}

data class DiffStats(val added: Int = 0, val removed: Int = 0)

data class TaskProgress(val done: Int = 0, val total: Int = 0) {
    val fraction: Float
        get() = if (total > 0) done.toFloat() / total.toFloat() else 0f
}

/** UI-friendly snapshot of `ServerMessage.GoalStatus` — keeps the
 *  full `Status` enum while only carrying the fields the banner
 *  needs to render. */
data class GoalStatusUi(
    val state: GoalState,
    val condition: String?,
    val reason: String?,
    val message: String,
)

/** UI-friendly snapshot of `ServerMessage.ModelStatus`. */
data class ModelStatusUi(
    val state: ModelState,
    val message: String?,
    val hubId: String?,
) {
    val isLoading: Boolean get() = state == ModelState.LOADING
}

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
    /**
     * Out-of-band informational row — e.g. "Synced 7 events from desktop"
     * after a reattach replay. Rendered as a low-emphasis grey line in the
     * transcript; never updates tool counts, agent running state, or the
     * auto-commit subject.
     */
    data class Notice(val text: String) : TranscriptItem
}

/**
 * Convert the in-memory transcript to the persisted shape. The id
 * prefix is what makes [SessionTranscriptLine] round-trip back into
 * a `TranscriptItem` on resume.
 */
internal fun TranscriptItem.toPersisted(): SessionTranscriptLine = when (this) {
    is TranscriptItem.User -> SessionTranscriptLine(
        id = "u:${text.hashCode()}",
        kind = SessionTranscriptLine.Kind.USER,
        text = text,
    )
    is TranscriptItem.Assistant -> SessionTranscriptLine(
        id = "a:${text.hashCode()}",
        kind = SessionTranscriptLine.Kind.ASSISTANT,
        text = text,
    )
    is TranscriptItem.Tool -> SessionTranscriptLine(
        id = "t:$id",
        kind = SessionTranscriptLine.Kind.TOOL,
        text = summary,
        tool = tool,
        ok = ok,
    )
    is TranscriptItem.Diff -> SessionTranscriptLine(
        id = "d:$id",
        kind = SessionTranscriptLine.Kind.DIFF,
        text = path,
        path = path,
        added = added,
        removed = removed,
    )
    is TranscriptItem.Notice -> SessionTranscriptLine(
        // Hash the text so the same notice appended twice is treated as
        // the same persisted row; collisions only collapse identical
        // notice strings, which is exactly what we want.
        id = "n:" + text.hashCode(),
        kind = SessionTranscriptLine.Kind.NOTICE,
        text = text,
    )
}
