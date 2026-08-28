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
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.SmartToy
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import app.roamsocket.android.ui.settings.SettingsViewModel
import app.roamsocket.core.protocol.E2bRun
import app.roamsocket.core.protocol.E2bRunState
import app.roamsocket.core.sandboxes.E2bPhoneRepoSelection
import app.roamsocket.core.sandboxes.E2bPhoneRepoSource
import app.roamsocket.core.sandboxes.E2bPhoneRunRequest
import kotlinx.coroutines.launch
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
    val container = LocalAppContainer.current
    var showKeySheet by remember { mutableStateOf(false) }
    var showStartSheet by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { viewModel.start() }
    androidx.compose.runtime.DisposableEffect(Unit) {
        onDispose { viewModel.stop() }
    }

    val unifiedRuns = remember(state.runs, state.phoneRuns) {
        buildUnifiedRuns(state.runs, state.phoneRuns)
    }

    ScaffoldTopBar(
        title = "Sandboxes",
        onBack = onBack,
        trailing = {
            IconButton(onClick = { showStartSheet = true }) {
                Icon(
                    imageVector = Icons.Filled.PlayArrow,
                    contentDescription = "Start a run",
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
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
                !state.isReady && state.runs.isEmpty() && state.phoneRuns.isEmpty() ->
                    ConnectingOrNoDesktopState(
                        errorMessage = errorMessage,
                        hasPhoneKey = container.e2bKeyStore.initialHasKey.value,
                        onStart = { showStartSheet = true },
                    )
                unifiedRuns.isEmpty() -> EmptyState(
                    hasPhoneKey = container.e2bKeyStore.initialHasKey.value,
                    onStart = { showStartSheet = true },
                )
                else -> RunsList(
                    runs = unifiedRuns,
                    onAbort = { row ->
                        when (row.source) {
                            RunSource.Phone -> { /* phone runs are short-lived; no abort needed */ }
                            RunSource.Desktop -> viewModel.abort(row.id)
                        }
                    },
                    onCopy = { text -> copyToClipboard(context, text) },
                    onOpenSandbox = { url -> openUrl(context, url) },
                )
            }
        }
    }

    if (showStartSheet) {
        StartRunSheet(
            onStart = { req ->
                viewModel.startPhoneRun(req)
                showStartSheet = false
            },
            onDismiss = { showStartSheet = false },
        )
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

private fun statusLabel(run: UnifiedRun): String = when (run.status) {
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

private fun openUrl(context: Context, url: String) {
    val parsed = runCatching { android.net.Uri.parse(url) }.getOrNull() ?: return
    val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, parsed).apply {
        addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    runCatching { context.startActivity(intent) }
}

// MARK: - Unified run model (desktop + phone)

/** Where a run originated. */
internal enum class RunSource { Desktop, Phone }

/** A row in the Sandboxes list. Wraps either a desktop-originated
 *  [E2bRun] (from the desktop WS) or a phone-originated
 *  [E2bPhoneRun] (no PC) so the UI can render both side-by-side. */
internal data class UnifiedRun(
    val id: String,
    val source: RunSource,
    val repoFullName: String,
    val branch: String,
    val status: E2bRunState,
    val exitCode: Int?,
    val sandboxUrl: String?,
    val command: String,
    val outputTail: List<String>,
    val error: String?,
    val startedAt: Long?,
) {
    companion object {
        fun fromDesktop(run: E2bRun): UnifiedRun = UnifiedRun(
            id = run.id,
            source = RunSource.Desktop,
            repoFullName = run.repoFullName,
            branch = run.branch,
            status = run.status,
            exitCode = run.exitCode,
            sandboxUrl = run.sandboxUrl,
            command = run.command,
            outputTail = run.outputTail,
            error = run.error,
            startedAt = run.startedAt,
        )

        fun fromPhone(run: app.roamsocket.core.sandboxes.E2bPhoneRun): UnifiedRun {
            val status = when (run.status) {
                "queued" -> E2bRunState.QUEUED
                "running" -> E2bRunState.RUNNING
                "completed" -> E2bRunState.COMPLETED
                "failed" -> E2bRunState.FAILED
                "killed" -> E2bRunState.KILLED
                else -> E2bRunState.QUEUED
            }
            return UnifiedRun(
                id = run.id,
                source = RunSource.Phone,
                repoFullName = run.repoFullName,
                branch = run.branch,
                status = status,
                exitCode = run.exitCode,
                sandboxUrl = run.sandboxUrl,
                command = run.command,
                outputTail = run.outputTail,
                error = run.error,
                startedAt = run.startedAt,
            )
        }
    }
}

private fun buildUnifiedRuns(
    desktop: List<E2bRun>,
    phone: List<app.roamsocket.core.sandboxes.E2bPhoneRun>,
): List<UnifiedRun> = (desktop.map(UnifiedRun::fromDesktop) + phone.map(UnifiedRun::fromPhone))
    .sortedByDescending { it.startedAt ?: 0L }

// MARK: - Empty / connecting states

@Composable
private fun EmptyState(hasPhoneKey: Boolean, onStart: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
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
            text = "Start a run from your phone to spin up a clean E2B sandbox — no PC required.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(14.dp))
        Button(onClick = onStart) {
            Icon(imageVector = Icons.Filled.PlayArrow, contentDescription = null)
            Spacer(Modifier.width(6.dp))
            Text("Start a run")
        }
        if (!hasPhoneKey) {
            Spacer(Modifier.height(8.dp))
            Text(
                text = "Add your e2b.dev key in Settings → Sandboxes (E2B) to start runs without a paired desktop.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ConnectingOrNoDesktopState(
    errorMessage: String?,
    hasPhoneKey: Boolean,
    onStart: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (errorMessage != null) {
            Icon(
                imageVector = Icons.Outlined.Cancel,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.error,
                modifier = Modifier.size(36.dp),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = errorMessage,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
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
        if (hasPhoneKey) {
            Spacer(Modifier.height(20.dp))
            Button(onClick = onStart) {
                Icon(imageVector = Icons.Filled.PlayArrow, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("Start a run")
            }
        }
    }
}

// MARK: - Run row (unified)

@Composable
private fun RunsList(
    runs: List<UnifiedRun>,
    onAbort: (UnifiedRun) -> Unit,
    onCopy: (String) -> Unit,
    onOpenSandbox: (String) -> Unit,
) {
    val context = LocalContext.current
    LazyColumn(
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        items(runs, key = { it.id }) { run ->
            UnifiedRunCard(
                run = run,
                onAbort = { onAbort(run) },
                onCopy = { onCopy(run.outputTail.joinToString("\n")) },
                onOpenSandbox = { url -> onOpenSandbox(url) },
            )
        }
    }
}

@Composable
private fun UnifiedRunCard(
    run: UnifiedRun,
    onAbort: () -> Unit,
    onCopy: () -> Unit,
    onOpenSandbox: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column {
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
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = run.repoFullName,
                            style = MaterialTheme.typography.bodyLarge,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        if (run.source == RunSource.Phone) {
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "PHONE",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onPrimary,
                                fontWeight = FontWeight.Bold,
                                modifier = Modifier
                                    .background(
                                        MaterialTheme.colorScheme.primary,
                                        RoundedCornerShape(50),
                                    )
                                    .padding(horizontal = 6.dp, vertical = 2.dp),
                            )
                        }
                    }
                    Text(
                        text = run.branch,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                    )
                }
                if (run.status == E2bRunState.RUNNING && run.source == RunSource.Desktop) {
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
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { expanded = !expanded }
                    .padding(horizontal = 12.dp)
                    .padding(bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (run.startedAt != null) {
                    Text(
                        text = formatRelative(run.startedAt),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    Spacer(modifier = Modifier.weight(1f))
                }
                val sandboxUrl = run.sandboxUrl
                if (sandboxUrl != null && sandboxUrl.isNotEmpty()) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clickable { onOpenSandbox(sandboxUrl) }
                            .padding(vertical = 2.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Link,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(10.dp),
                        )
                        Spacer(Modifier.width(2.dp))
                        Text(
                            text = sandboxUrl,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.primary,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                        )
                    }
                }
            }
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

// MARK: - Start a run sheet

/**
 * Bottom sheet for the "Start a run" flow. Lets the user pick a
 * GitHub repo or paste a URL, a branch, and a command. Submits a
 * phone-originated run to the ViewModel — the phone talks to
 * e2b.dev directly, no desktop required.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StartRunSheet(
    onStart: (E2bPhoneRunRequest) -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val container = LocalAppContainer.current
    val scope = rememberCoroutineScope()
    var source by remember { mutableStateOf(E2bPhoneRepoSource.github) }
    var url by remember { mutableStateOf("") }
    var branch by remember { mutableStateOf("main") }
    var command by remember { mutableStateOf("ls -la") }
    var showRepoPicker by remember { mutableStateOf(false) }
    var hasGitHubToken by remember { mutableStateOf(false) }
    var pickedRepo by remember { mutableStateOf<app.roamsocket.core.github.GitHubRepo?>(null) }

    LaunchedEffect(Unit) {
        hasGitHubToken = !container.secretStore.readSecret(
            SettingsViewModel.KEY_GITHUB_PAT,
        ).isNullOrEmpty()
    }

    val isValid = when (source) {
        E2bPhoneRepoSource.github ->
            pickedRepo != null && branch.isNotBlank() && command.isNotBlank()
        E2bPhoneRepoSource.url ->
            url.isNotBlank() && branch.isNotBlank() && command.isNotBlank()
    }

    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "Start a run",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
            Spacer(Modifier.height(8.dp))
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                SegmentedButton(
                    selected = source == E2bPhoneRepoSource.github,
                    onClick = { source = E2bPhoneRepoSource.github },
                    shape = SegmentedButtonDefaults.itemShape(
                        index = 0,
                        count = 2,
                    ),
                ) { Text("My GitHub repos") }
                SegmentedButton(
                    selected = source == E2bPhoneRepoSource.url,
                    onClick = { source = E2bPhoneRepoSource.url },
                    shape = SegmentedButtonDefaults.itemShape(
                        index = 1,
                        count = 2,
                    ),
                ) { Text("Paste a URL") }
            }
            Spacer(Modifier.height(12.dp))

            if (source == E2bPhoneRepoSource.github) {
                OutlinedButton(
                    onClick = { showRepoPicker = true },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = hasGitHubToken,
                ) {
                    Text(pickedRepo?.fullName ?: (if (hasGitHubToken) "Select repo" else "Link a GitHub PAT in Settings"))
                }
            } else {
                OutlinedTextField(
                    value = url,
                    onValueChange = { url = it },
                    label = { Text("Git URL") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.None,
                        autoCorrectEnabled = false,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = branch,
                onValueChange = { branch = it },
                label = { Text("Branch") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = command,
                onValueChange = { command = it },
                label = { Text("Command") },
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                ),
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                text = "Runs inside the cloned repo at /code. Examples: npm test, pytest -q, cargo test --quiet.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(16.dp))
            Button(
                onClick = {
                    val repo = when (source) {
                        E2bPhoneRepoSource.github ->
                            E2bPhoneRepoSelection.Github(
                                pickedRepo?.fullName ?: return@Button
                            )
                        E2bPhoneRepoSource.url ->
                            E2bPhoneRepoSelection.Url(
                                url.trim()
                            )
                    }
                    scope.launch {
                        val githubToken = container.secretStore.readSecret(
                            SettingsViewModel.KEY_GITHUB_PAT,
                        )
                        onStart(
                            E2bPhoneRunRequest(
                                repo = repo,
                                branch = branch.trim(),
                                command = command.trim(),
                                githubToken = githubToken,
                            ),
                        )
                    }
                },
                enabled = isValid,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(imageVector = Icons.Filled.PlayArrow, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("Start")
            }
            Spacer(Modifier.height(16.dp))
        }
    }

    if (showRepoPicker) {
        app.roamsocket.android.ui.repositories.RepositoryPickerSheet(
            onPick = { repo ->
                pickedRepo = repo
                if (branch.isBlank() || branch == "main") {
                    branch = repo.defaultBranch
                }
                showRepoPicker = false
            },
            onLinkGitHub = {
                // The picker itself raises its own GitHub link flow.
                // Close ours on top so the user doesn't see two
                // sheets stack.
                showRepoPicker = false
            },
            onDismiss = { showRepoPicker = false },
        )
    }
}
