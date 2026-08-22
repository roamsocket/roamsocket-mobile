package app.roamsocket.android.ui.session

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.NetworkCheck
import androidx.compose.material.icons.outlined.OpenInBrowser
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.protocol.ClientMessage
import app.roamsocket.core.protocol.ListeningPort
import app.roamsocket.core.protocol.ServerMessage
import app.roamsocket.core.server.Endpoint
import app.roamsocket.core.server.WorkspaceRpc
import kotlinx.coroutines.launch

/**
 * Lists listening ports on the desktop for this coding session. Each
 * row exposes a "Preview on phone" button that starts a tunnel via
 * `tunnel_start` and opens the resulting public URL in the system
 * browser. Mirrors the iOS `PortManagerView`
 * (`ios/.../SessionToolsView.swift`).
 */
@Composable
fun PortManagerPane(
    sessionId: String,
    endpoint: Endpoint?,
    token: String?,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val state = remember { PortManagerState() }
    val context = LocalContext.current
    val canStart = endpoint != null && !token.isNullOrEmpty()

    LaunchedEffect(sessionId, endpoint?.baseURL, token) {
        if (canStart) state.reload(scope, endpoint!!, token!!, sessionId)
        else state.errorMessage = "Pair a desktop server first."
    }

    Box(modifier = modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(vertical = 4.dp),
        ) {
            state.errorMessage?.let { err ->
                item {
                    Text(
                        text = err,
                        color = MaterialTheme.colorScheme.error,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
            state.lastPreviewURL?.let { url ->
                item("last") {
                    Text(
                        text = "Last preview",
                        color = Palette.TextPrimary,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                runCatching {
                                    context.startActivity(
                                        Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                    )
                                }
                            }
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                    ) {
                        Text(
                            text = url,
                            color = Palette.Accent,
                            fontSize = 13.sp,
                            fontFamily = FontFamily.Monospace,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
            item("header") {
                Text(
                    text = "Listening on desktop",
                    color = Palette.TextPrimary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
            if (state.ports.isEmpty() && !state.loading) {
                item("empty") {
                    Text(
                        text = "No listening ports found.",
                        color = Palette.TextSecondary,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
            }
            items(state.ports, key = { it.port }) { entry ->
                PortRow(
                    entry = entry,
                    isBusy = state.busyPort == entry.port,
                    enabled = canStart && state.busyPort == null,
                    onPreview = {
                        if (canStart) {
                            scope.launch {
                                state.preview(context, endpoint!!, token!!, sessionId, entry.port)
                            }
                        }
                    },
                )
            }
        }
        if (state.loading && state.ports.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            }
        }
    }
}

@Composable
private fun PortRow(
    entry: ListeningPort,
    isBusy: Boolean,
    enabled: Boolean,
    onPreview: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Outlined.NetworkCheck,
                contentDescription = null,
                tint = Palette.Accent,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.size(8.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = ":${entry.port}",
                    color = Palette.TextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                )
                Text(
                    text = "pid ${entry.pid} · ${entry.command}",
                    color = Palette.TextTertiary,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
        Spacer(Modifier.size(6.dp))
        Button(
            onClick = onPreview,
            enabled = enabled,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (isBusy) {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    strokeWidth = 1.5.dp,
                    color = MaterialTheme.colorScheme.onPrimary,
                )
            } else {
                Icon(
                    imageVector = Icons.Outlined.OpenInBrowser,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.size(6.dp))
                Text("Preview on phone")
            }
        }
    }
}

internal class PortManagerState {
    var ports: List<ListeningPort> by mutableStateOf(emptyList())
    var loading: Boolean by mutableStateOf(false)
    var errorMessage: String? by mutableStateOf(null)
    var busyPort: Int? by mutableStateOf(null)
    var lastPreviewURL: String? by mutableStateOf(null)

    suspend fun reload(
        scope: kotlinx.coroutines.CoroutineScope,
        endpoint: Endpoint,
        token: String,
        sessionId: String,
    ) {
        loading = true
        try {
            val list = WorkspaceRpc.withConnection(
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
            ports = list
            errorMessage = null
        } catch (e: Throwable) {
            errorMessage = e.message ?: e.javaClass.simpleName
        } finally {
            loading = false
        }
    }

    suspend fun preview(
        context: android.content.Context,
        endpoint: Endpoint,
        token: String,
        sessionId: String,
        port: Int,
    ) {
        busyPort = port
        try {
            val tunnels = WorkspaceRpc.withConnection(
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
                        is ServerMessage.Error -> { errorMessage = msg.message; null }
                        else -> null
                    }
                },
            )
            val url = tunnels.firstOrNull { it.port == port }?.url
            if (url != null) {
                lastPreviewURL = url
                runCatching {
                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
                errorMessage = null
            } else {
                errorMessage = "Tunnel started but no URL yet — pull to refresh and try again."
            }
        } catch (e: Throwable) {
            errorMessage = e.message ?: e.javaClass.simpleName
        } finally {
            busyPort = null
        }
    }
}
