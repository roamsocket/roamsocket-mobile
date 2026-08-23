package app.roamsocket.android.ui.code

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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.DesktopWindows
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Menu
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.roamsocket.android.data.PairedServer
import app.roamsocket.android.ui.LocalOpenSidebar
import app.roamsocket.android.ui.codesessions.CodeSessionList
import app.roamsocket.android.ui.repositories.RepositoryPickerSheet
import app.roamsocket.android.ui.session.SessionConfig
import app.roamsocket.android.ui.session.SessionModelSelection
import app.roamsocket.android.ui.session.SessionScreen
import app.roamsocket.core.code.CodeSession
import app.roamsocket.core.github.GitHubRepo
import app.roamsocket.core.protocol.RepoRef
import app.roamsocket.core.providers.ProviderId
import app.roamsocket.core.server.Endpoint
import kotlinx.coroutines.launch

/**
 * Code tab — pair with a desktop server, see the active connection, and
 * start a coding session. The session itself is handled by [SessionScreen]
 * which we navigate to once the user confirms a [SessionConfig].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CodeScreen(
    onNavigateToSettings: () -> Unit = {},
    viewModel: PairingViewModel = viewModel(factory = PairingViewModel.Factory),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val paired by viewModel.paired.collectAsStateWithLifecycle()
    val nearby by viewModel.nearbyEndpoints.collectAsStateWithLifecycle()
    val sessions by viewModel.activeSessions.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    var showNewSessionDialog by remember { mutableStateOf(false) }
    var activeConfig by remember { mutableStateOf<Pair<SessionConfig, PairedServer>?>(null) }

    Column(modifier = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        TopAppBar(
            navigationIcon = {
                IconButton(onClick = LocalOpenSidebar.current) {
                    Icon(
                        imageVector = Icons.Outlined.Menu,
                        contentDescription = "Open sidebar",
                        tint = MaterialTheme.colorScheme.onSurface,
                    )
                }
            },
            title = { Text("Code") },
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = MaterialTheme.colorScheme.surface,
                titleContentColor = MaterialTheme.colorScheme.onSurface,
            ),
        )

        state.error?.let { err ->
            ErrorRow(message = err, onDismiss = viewModel::dismissError)
        }

        LazyColumn(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                val current = paired
                if (current != null) {
                    PairedServerCard(
                        server = current,
                        onForget = viewModel::forget,
                        onStartSession = { showNewSessionDialog = true },
                    )
                } else {
                    PairForm(
                        state = state,
                        nearby = nearby,
                        onHostChange = viewModel::setHostInput,
                        onCodeChange = viewModel::setCodeInput,
                        onPickEndpoint = viewModel::pickEndpoint,
                        onPair = viewModel::pair,
                    )
                }
            }
            item {
                CodeSessionList(
                    sessions = sessions,
                    onOpen = { session ->
                        // Re-attach: rebuild a SessionConfig from the saved
                        // session and launch SessionScreen. A later PR adds
                        // proper "reattach to running session" semantics;
                        // for now we just open a fresh session with the
                        // same repo/branch.
                        val p = paired
                        if (p != null) {
                            scope.launch {
                                val base = viewModel.defaultSessionConfig()
                                if (base != null) {
                                    val config = base.copy(
                                        repo = RepoRef(
                                            fullName = session.repoFullName,
                                            baseBranch = session.baseBranch,
                                            workBranch = session.workBranch,
                                        ),
                                    )
                                    activeConfig = config to p
                                }
                            }
                        }
                    },
                    onArchive = { viewModel.archiveSession(it.id) },
                )
            }
            if (paired == null && nearby.isNotEmpty()) {
                item {
                    Text(
                        text = "Nearby servers",
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
                items(nearby, key = { it.baseURL }) { endpoint ->
                    NearbyServerRow(endpoint = endpoint, onPick = { viewModel.pickEndpoint(endpoint) })
                }
            }
        }
    }

    if (showNewSessionDialog && paired != null) {
        NewSessionSheet(
            viewModel = viewModel,
            onDismiss = { showNewSessionDialog = false },
            onStart = { config ->
                showNewSessionDialog = false
                activeConfig = config to paired!!
            },
            onNavigateToSettings = {
                showNewSessionDialog = false
                onNavigateToSettings()
            },
        )
    }

    activeConfig?.let { (config, server) ->
        SessionScreen(
            config = config,
            paired = server,
            onBack = { activeConfig = null },
        )
    }
}

@Composable
private fun PairForm(
    state: PairingUiState,
    nearby: List<Endpoint>,
    onHostChange: (String) -> Unit,
    onCodeChange: (String) -> Unit,
    onPickEndpoint: (Endpoint) -> Unit,
    onPair: () -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                text = "Pair with desktop",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Open the desktop server, then type the 6-character code shown there.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = state.hostInput,
                onValueChange = onHostChange,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Server address") },
                placeholder = { Text("192.168.1.10:4319") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    keyboardType = KeyboardType.Uri,
                    imeAction = ImeAction.Next,
                ),
            )
            OutlinedTextField(
                value = state.codeInput,
                onValueChange = onCodeChange,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Pairing code") },
                placeholder = { Text("ABC123") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.Characters,
                    keyboardType = KeyboardType.Ascii,
                    imeAction = ImeAction.Done,
                ),
            )
            Button(
                onClick = onPair,
                enabled = !state.isPairing && state.codeInput.length == 6,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (state.isPairing) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.onPrimary,
                    )
                } else {
                    Text("Pair")
                }
            }
        }
    }
}

@Composable
private fun PairedServerCard(
    server: PairedServer,
    onForget: () -> Unit,
    onStartSession: () -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Outlined.Link,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                )
                Text(
                    text = " Paired",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(start = 8.dp),
                )
            }
            Text(
                text = server.serverName,
                style = MaterialTheme.typography.bodyLarge,
            )
            Text(
                text = "v" + server.serverVersion,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            HorizontalDivider()
            Text(
                text = "Endpoint",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = server.endpoint,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            )
            if (!server.publicUrl.isNullOrEmpty()) {
                Text(
                    text = "Public",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp),
                )
                Text(
                    text = server.publicUrl,
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                )
            }
            Button(onClick = onStartSession, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.PlayArrow, contentDescription = null)
                Text(" Start a coding session", modifier = Modifier.padding(start = 8.dp))
            }
            OutlinedButton(onClick = onForget, modifier = Modifier.fillMaxWidth()) {
                Text("Forget this server")
            }
        }
    }
}

@Composable
private fun NearbyServerRow(endpoint: Endpoint, onPick: () -> Unit) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Outlined.DesktopWindows,
                contentDescription = null,
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surface)
                    .padding(6.dp),
                tint = MaterialTheme.colorScheme.primary,
            )
            Column(modifier = Modifier.weight(1f).padding(horizontal = 12.dp)) {
                Text(
                    text = endpoint.baseURL,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                )
                Text(
                    text = "Discovered on LAN",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            TextButton(onClick = onPick) { Text("Use") }
        }
    }
}

@Composable
private fun ErrorRow(message: String, onDismiss: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.error,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = message,
                color = MaterialTheme.colorScheme.onError,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onDismiss) {
                Icon(Icons.Outlined.Refresh, contentDescription = "Dismiss", tint = MaterialTheme.colorScheme.onError)
            }
        }
    }
}

// (end)
