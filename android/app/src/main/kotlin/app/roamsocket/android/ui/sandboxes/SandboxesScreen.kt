package app.roamsocket.android.ui.sandboxes

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.SmartToy
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import app.roamsocket.android.ui.LocalAppContainer
import app.roamsocket.core.protocol.E2bRun
import app.roamsocket.core.protocol.E2bRunState
import java.text.DateFormat
import java.util.Date

/**
 * Sandboxes (E2B) — shows the runs the desktop server kicked off after
 * each `git_publish`, lets the user set a per-connection override API
 * key, and (when the server has admin keys configured) re-run a
 * session.
 *
 * Opens its own WebSocket so the user can keep streaming logs after the
 * chat or code session has been dismissed.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SandboxesScreen(
    onBack: () -> Unit,
    viewModel: SandboxesViewModel = viewModel(
        factory = SandboxesViewModel.factoryFor(LocalAppContainer.current),
    ),
) {
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current
    var showKeySheet by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { viewModel.start() }
    androidx.compose.runtime.DisposableEffect(Unit) {
        onDispose { viewModel.stop() }
    }

    ScaffoldTopBar(
        title = "Sandboxes",
        onBack = onBack,
        trailing = {
            IconButton(onClick = { showKeySheet = true }) {
                Icon(
                    imageVector = Icons.Outlined.Key,
                    contentDescription = "E2B key",
                    tint = if (state.hasUserKey) MaterialTheme.colorScheme.primary
                           else MaterialTheme.colorScheme.onSurface,
                )
            }
        },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                !state.isReady -> ConnectingState(errorMessage)
                state.runs.isEmpty() -> EmptyState()
                else -> RunsList(
                    runs = state.runs,
                    onAbort = { viewModel.abort(it) },
                    onCopy = { copyToClipboard(context, it) },
                )
            }
        }
    }

    if (showKeySheet) {
        E2bKeySheet(
            hasUserKey = state.hasUserKey,
            onSave = { key ->
                viewModel.setKey(key)
                showKeySheet = false
            },
            onClear = {
                viewModel.setKey("")
                showKeySheet = false
            },
            onDismiss = { showKeySheet = false },
        )
    }

    state.lastError?.let { err ->
        AlertDialog(
            onDismissRequest = viewModel::dismissError,
            title = { Text("Sandbox error") },
            text = { Text(err) },
            confirmButton = {
                TextButton(onClick = viewModel::dismissError) { Text("OK") }
            },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScaffoldTopBar(
    title: String,
    onBack: () -> Unit,
    trailing: @Composable () -> Unit,
    content: @Composable (androidx.compose.foundation.layout.PaddingValues) -> Unit,
) {
    androidx.compose.material3.Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = androidx.compose.material.icons.Icons.AutoMirrored.Outlined.ArrowBack,
                            contentDescription = "Back",
                        )
                    }
                },
                actions = { trailing() },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
        content = content,
    )
}

@Composable
private fun ConnectingState(error: String?) {
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (error != null) {
            Icon(
                imageVector = Icons.Outlined.Cancel,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.error,
                modifier = Modifier.size(36.dp),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = error,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "Pair a desktop server in Settings, then reopen this screen.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.height(12.dp))
            Text(
                text = "Connecting to desktop…",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun EmptyState() {
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = Icons.Outlined.SmartToy,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(40.dp),
        )
        Spacer(Modifier.height(10.dp))
        Text(
            text = "No sandbox runs yet",
            style = MaterialTheme.typography.bodyLarge,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = "After you push a branch, the desktop server can spin up an E2B sandbox to run it. Configure the admin key on the desktop, or set your own.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun RunsList(
    runs: List<E2bRun>,
    onAbort: (String) -> Unit,
    onCopy: (String) -> Unit,
) {
    LazyColumn(
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        items(runs, key = { it.id }) { run ->
            RunCard(
                run = run,
                onAbort = { onAbort(run.id) },
                onCopy = { onCopy(run.outputTail.joinToString("\n")) },
            )
        }
    }
}

@Composable
private fun RunCard(
    run: E2bRun,
    onAbort: () -> Unit,
    onCopy: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column {
            // Header
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { expanded = !expanded }
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .background(statusTint(run.status), shape = RoundedCornerShape(50)),
                )
                Spacer(Modifier.width(8.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = run.repoFullName,
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                    )
                    Text(
                        text = run.branch,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                    )
                }
                if (run.status == E2bRunState.RUNNING) {
                    IconButton(onClick = onAbort) {
                        Icon(
                            imageVector = Icons.Outlined.Cancel,
                            contentDescription = "Stop",
                            tint = MaterialTheme.colorScheme.error,
                        )
                    }
                } else {
                    Text(
                        text = statusLabel(run),
                        style = MaterialTheme.typography.labelSmall,
                        color = statusTint(run.status),
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            // Meta
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { expanded = !expanded }
                    .padding(horizontal = 12.dp)
                    .padding(bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (run.startedAt != null) {
                    val startedAt: Long = run.startedAt!!
                    Text(
                        text = formatRelative(startedAt),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    Spacer(modifier = Modifier.weight(1f))
                }
                val sandboxUrl = run.sandboxUrl
                if (sandboxUrl != null && sandboxUrl.isNotEmpty()) {
                    Text(
                        text = sandboxUrl,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                    )
                }
            }
            // Expanded body
            if (expanded) {
                androidx.compose.material3.HorizontalDivider(
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.2f),
                )
                Column(modifier = Modifier.padding(12.dp)) {
                    if (run.command.isNotEmpty()) {
                        Text(
                            text = "$ ${run.command}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontFamily = FontFamily.Monospace,
                        )
                        Spacer(Modifier.height(6.dp))
                    }
                    if (run.outputTail.isNotEmpty()) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState())
                                .background(
                                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
                                    RoundedCornerShape(8.dp),
                                )
                                .padding(8.dp),
                        ) {
                            Text(
                                text = run.outputTail.joinToString("\n"),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurface,
                                fontFamily = FontFamily.Monospace,
                            )
                        }
                    } else {
                        Text(
                            text = "No output yet.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    run.error?.let { err ->
                        if (err.isNotEmpty()) {
                            Spacer(Modifier.height(6.dp))
                            Row(verticalAlignment = Alignment.Top) {
                                Icon(
                                    imageVector = Icons.Outlined.Cancel,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.size(14.dp),
                                )
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    text = err,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.error,
                                )
                            }
                        }
                    }
                    if (run.outputTail.isNotEmpty()) {
                        Spacer(Modifier.height(8.dp))
                        Row(horizontalArrangement = Arrangement.End) {
                            IconButton(onClick = onCopy) {
                                Icon(
                                    imageVector = Icons.Outlined.ContentCopy,
                                    contentDescription = "Copy output",
                                    tint = MaterialTheme.colorScheme.primary,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun statusLabel(run: E2bRun): String = when (run.status) {
    E2bRunState.QUEUED -> "QUEUED"
    E2bRunState.RUNNING -> "RUNNING"
    E2bRunState.COMPLETED -> "DONE · ${run.exitCode ?: 0}"
    E2bRunState.FAILED -> "FAILED · ${run.exitCode ?: "—"}"
    E2bRunState.KILLED -> "KILLED"
}

@Composable
private fun statusTint(state: E2bRunState): Color = when (state) {
    E2bRunState.COMPLETED -> MaterialTheme.colorScheme.primary
    E2bRunState.FAILED, E2bRunState.KILLED -> MaterialTheme.colorScheme.error
    E2bRunState.RUNNING -> MaterialTheme.colorScheme.primary
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

private fun formatRelative(epochMillis: Long): String {
    val now = System.currentTimeMillis()
    val diff = now - epochMillis
    return when {
        diff < 60_000L -> "just now"
        diff < 3_600_000L -> "${diff / 60_000L} min ago"
        diff < 86_400_000L -> "${diff / 3_600_000L} h ago"
        else -> DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(epochMillis))
    }
}

@Composable
private fun E2bKeySheet(
    hasUserKey: Boolean,
    onSave: (String) -> Unit,
    onClear: () -> Unit,
    onDismiss: () -> Unit,
) {
    var draft by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Your E2B key") },
        text = {
            Column {
                Text(
                    text = "Paste an e2b.dev API key to override the admin-managed key on the desktop. The override is held in memory only and clears on disconnect.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.None,
                        autoCorrectEnabled = false,
                    ),
                    placeholder = { Text("e2b_…") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSave(draft) },
                enabled = draft.isNotBlank(),
            ) { Text("Save") }
        },
        dismissButton = {
            Row {
                if (hasUserKey) {
                    TextButton(onClick = onClear) {
                        Text("Clear", color = MaterialTheme.colorScheme.error)
                    }
                }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

private fun copyToClipboard(context: Context, text: String) {
    if (text.isEmpty()) return
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
    cm?.setPrimaryClip(ClipData.newPlainText("RoamSocket sandbox output", text))
}
