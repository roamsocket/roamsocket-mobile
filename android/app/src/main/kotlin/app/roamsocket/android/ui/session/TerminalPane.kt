package app.roamsocket.android.ui.session

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.protocol.ClientMessage
import app.roamsocket.core.protocol.ServerMessage
import app.roamsocket.core.server.Endpoint
import app.roamsocket.core.server.ServerClient
import app.roamsocket.core.server.Session
import app.roamsocket.core.server.WorkspaceRpc
import app.roamsocket.core.server.WorkspaceRpcError
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Live shell pane over WebSocket — mirrors the iOS `TerminalPaneView`
 * (`ios/.../SessionToolsView.swift`).
 *
 * Wire flow:
 *  - `terminal_open { sessionId, cols, rows }` → server returns
 *    `terminal_control { event: "ready" }` with the assigned
 *    `terminalId`.
 *  - User input → `terminal_input { data }`.
 *  - On dispose → `terminal_kill { terminalId }`.
 */
@Composable
fun TerminalPane(
    sessionId: String,
    endpoint: Endpoint?,
    token: String?,
    modifier: Modifier = Modifier,
) {
    val state = remember { TerminalPaneState() }
    val scope = rememberCoroutineScope()
    val canStart = endpoint != null && !token.isNullOrEmpty()

    LaunchedEffect(sessionId, endpoint?.baseURL, token) {
        if (canStart) {
            state.start(scope, endpoint!!, token!!, sessionId)
        } else {
            state.connectionError = "Pair a desktop server first."
        }
    }
    DisposableEffect(Unit) {
        onDispose { state.stop() }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
    ) {
        TerminalStatusStrip(
            sessionId = sessionId,
            isRunning = state.isRunning,
            canStart = canStart,
            onKill = { state.stop() },
            onReconnect = {
                if (canStart) state.start(scope, endpoint!!, token!!, sessionId)
            },
        )
        TerminalOutput(
            output = state.output,
            modifier = Modifier.weight(1f),
        )
        state.connectionError?.let { err ->
            Text(
                text = err,
                color = MaterialTheme.colorScheme.error,
                fontSize = 12.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.Surface)
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            )
        }
        TerminalInput(
            isRunning = state.isRunning,
            onSend = { state.send(it) },
        )
    }
}

@Composable
private fun TerminalStatusStrip(
    sessionId: String,
    isRunning: Boolean,
    canStart: Boolean,
    onKill: () -> Unit,
    onReconnect: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.Surface)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(if (isRunning) Palette.Success else MaterialTheme.colorScheme.error),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = if (isRunning) "Shell live · $sessionId" else "Disconnected",
            color = Palette.TextSecondary,
            fontSize = 12.sp,
            fontFamily = FontFamily.Monospace,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (isRunning) {
            IconButton(onClick = onKill) {
                Icon(
                    Icons.Outlined.Cancel,
                    contentDescription = "Kill shell",
                    tint = MaterialTheme.colorScheme.error,
                )
            }
        } else if (canStart) {
            IconButton(onClick = onReconnect) {
                Text(
                    text = "Reconnect",
                    color = Palette.Accent,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                )
            }
        }
    }
}

@Composable
private fun TerminalOutput(output: String, modifier: Modifier = Modifier) {
    val scroll = rememberScrollState()
    LaunchedEffect(output) {
        scroll.animateScrollTo(scroll.maxValue)
    }
    val display = if (output.isEmpty()) {
        "SSH console — shell opens in the session workdir on your desktop.\nType a command and press Return."
    } else {
        output
    }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(Color(0xCC101418))
            .verticalScroll(scroll)
            .padding(12.dp),
    ) {
        Text(
            text = display,
            color = Palette.TextPrimary,
            fontSize = 12.sp,
            fontFamily = FontFamily.Monospace,
        )
    }
}

@Composable
private fun TerminalInput(
    isRunning: Boolean,
    onSend: (String) -> Unit,
) {
    var input by remember { mutableStateOf(TextFieldValue("")) }
    Surface(
        color = Palette.SurfaceElevated,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
        ) {
            Text(
                text = "$",
                color = Palette.Accent,
                fontSize = 14.sp,
                fontFamily = FontFamily.Monospace,
            )
            Spacer(Modifier.width(8.dp))
            Box(modifier = Modifier.weight(1f)) {
                if (input.text.isEmpty()) {
                    Text(
                        text = "command",
                        color = Palette.TextTertiary,
                        fontSize = 14.sp,
                        fontFamily = FontFamily.Monospace,
                    )
                }
                BasicTextField(
                    value = input,
                    onValueChange = { input = it },
                    textStyle = TextStyle(
                        color = Palette.TextPrimary,
                        fontSize = 14.sp,
                        fontFamily = FontFamily.Monospace,
                    ),
                    cursorBrush = SolidColor(Palette.Accent),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            IconButton(
                onClick = {
                    val cmd = input.text
                    if (cmd.isNotEmpty()) {
                        onSend(cmd)
                        input = TextFieldValue("")
                    } else if (isRunning) {
                        onSend("\n")
                    }
                },
                enabled = isRunning || input.text.isNotEmpty(),
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.Send,
                    contentDescription = "Send",
                    tint = Palette.Accent,
                )
            }
        }
    }
}

/** Per-pane ViewModel-less state holder. */
internal class TerminalPaneState {
    var output: String by mutableStateOf("")
    var isRunning: Boolean by mutableStateOf(false)
    var connectionError: String? by mutableStateOf(null)

    private var client: ServerClient? = null
    private var session: Session? = null
    private var terminalId: String? = null
    private var streamJob: Job? = null
    private var scope: kotlinx.coroutines.CoroutineScope? = null

    fun start(
        scope: kotlinx.coroutines.CoroutineScope,
        endpoint: Endpoint,
        token: String,
        sessionId: String,
    ) {
        if (streamJob != null) return
        this.scope = scope
        connectionError = null
        isRunning = true
        streamJob = scope.launch {
            try {
                val c = ServerClient()
                client = c
                val s = c.connect(endpoint, token)
                session = s
                s.send(
                    ClientMessage.TerminalOpen(
                        terminalId = null,
                        sessionId = sessionId,
                        cols = 80,
                        rows = 24,
                    ),
                )
                appendOutput("Connected to session workdir shell.\n")
                s.incoming.collectLatest { handle(it) }
                if (isRunning) {
                    connectionError = "Shell disconnected."
                    isRunning = false
                }
            } catch (e: Throwable) {
                if (e is WorkspaceRpcError) {
                    connectionError = e.message
                } else {
                    connectionError = e.message ?: e.javaClass.simpleName
                }
                isRunning = false
            }
        }
    }

    fun send(text: String) {
        val id = terminalId
        if (id == null) {
            // Echo locally for responsiveness before the server hands us a terminalId.
            output += text
            return
        }
        val s = session ?: return
        // Mirror iOS: local echo + send.
        if (output.isNotEmpty() && !output.endsWith("\n")) output += "\n"
        output += "$ $text"
        scope?.launch { runCatching { s.send(ClientMessage.TerminalInput(id, data = "$text\n")) } }
    }

    fun stop() {
        val id = terminalId
        val s = session
        if (id != null && s != null) {
            scope?.launch { runCatching { s.send(ClientMessage.TerminalKill(id)) } }
        }
        streamJob?.cancel()
        streamJob = null
        isRunning = false
        runCatching { session?.close() }
        session = null
        client = null
    }

    private fun handle(message: ServerMessage) {
        when (message) {
            is ServerMessage.TerminalControl -> {
                if (message.event == app.roamsocket.core.protocol.TerminalEvent.READY) {
                    terminalId = message.terminalId
                    appendOutput("$ ")
                } else if (message.event == app.roamsocket.core.protocol.TerminalEvent.EXIT) {
                    isRunning = false
                    appendOutput("\n[process exited ${message.code}]\n")
                }
            }
            is ServerMessage.TerminalData -> appendOutput(message.data)
            is ServerMessage.Error -> {
                connectionError = message.message
                appendOutput("\nError: ${message.message}\n")
            }
            else -> Unit
        }
    }

    private fun appendOutput(s: String) {
        // Throttle by simply appending; the LazyColumn/verticalScroll
        // re-render is cheap for terminal-sized output.
        output += s
    }
}
