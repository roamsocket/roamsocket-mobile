/*
 * Top-level MCP / Connectors screen. Mirrors the iOS
 * `ConnectorManagerView` (formerly `MCPManagerView`).
 *
 * List of configured servers with toggles, an "Add connector" CTA,
 * and an empty state explaining the desktop-managed sync model.
 */
package app.roamsocket.android.ui.mcp

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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import app.roamsocket.android.ui.LocalAppContainer
import app.roamsocket.android.ui.LocalOpenSidebar
import app.roamsocket.core.protocol.MCPServer

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MCPScreen(
    onBack: () -> Unit,
    viewModel: MCPViewModel = viewModel(
        key = "MCPScreen",
        factory = MCPViewModel.factory(LocalAppContainer.current),
    ),
) {
    val state by viewModel.uiState.collectAsState()
    var showAddSheet by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { viewModel.preload() }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = LocalOpenSidebar.current) {
                        Icon(Icons.Outlined.ArrowBack, contentDescription = "Back")
                    }
                },
                title = {
                    Text(
                        "Connectors",
                        style = MaterialTheme.typography.titleMedium,
                    )
                },
                actions = {
                    IconButton(onClick = { viewModel.refresh() }) {
                        Icon(Icons.Outlined.Refresh, contentDescription = "Refresh")
                    }
                    IconButton(onClick = { showAddSheet = true }) {
                        Icon(Icons.Outlined.Add, contentDescription = "Add connector")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                    titleContentColor = MaterialTheme.colorScheme.onSurface,
                ),
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
        Column(modifier = Modifier.padding(padding).fillMaxSize()) {
            state.lastSyncError?.let { err ->
                ErrorBanner(message = err, onDismiss = viewModel::dismissError)
            }
            if (state.servers.isEmpty()) {
                EmptyConnectorsState(isPaired = state.isPaired)
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(vertical = 8.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    items(state.servers, key = { it.id }) { server ->
                        MCPServerRow(
                            server = server,
                            onToggle = { viewModel.toggleServer(server.id) },
                        )
                        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                    }
                }
            }
        }
    }

    if (showAddSheet) {
        AddMCPServerSheet(
            onDismiss = { showAddSheet = false },
            onSave = { name, desc, command, args, env ->
                viewModel.addServer(name, desc, command, args, env)
                showAddSheet = false
            },
        )
    }
}

@Composable
private fun MCPServerRow(server: MCPServer, onToggle: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Outlined.Dns,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(20.dp),
            )
        }
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                server.name,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                buildString {
                    append(server.command)
                    if (server.args.isNotEmpty()) {
                        append(" ")
                        append(server.args.joinToString(" "))
                    }
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (server.description.isNotEmpty()) {
                Text(
                    server.description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Spacer(modifier = Modifier.width(8.dp))
        Switch(
            checked = server.isEnabled,
            onCheckedChange = { onToggle() },
            colors = SwitchDefaults.colors(
                checkedThumbColor = MaterialTheme.colorScheme.onPrimary,
                checkedTrackColor = MaterialTheme.colorScheme.primary,
            ),
        )
    }
}

@Composable
private fun EmptyConnectorsState(isPaired: Boolean) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Outlined.Dns,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(48.dp),
        )
        Spacer(Modifier.height(16.dp))
        Text(
            "No connectors",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            if (isPaired) {
                "Add connectors via the + button. They're synced from your connector repo."
            } else {
                "Pair with a desktop and add MCP servers to extend the agent with custom tools."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ErrorBanner(message: String, onDismiss: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.errorContainer,
        contentColor = MaterialTheme.colorScheme.onErrorContainer,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            Text(
                message,
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.bodyMedium,
            )
            TextButton(onClick = onDismiss) { Text("Dismiss") }
        }
    }
}
