package app.roamsocket.android.ui.session

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.DataObject
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Menu
import androidx.compose.material.icons.outlined.NetworkCheck
import androidx.compose.material.icons.outlined.QuestionMark
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.roamsocket.android.data.PairedServer
import app.roamsocket.android.data.PairedServerStore
import app.roamsocket.android.ui.LocalAppContainer
import app.roamsocket.android.ui.chat.AssistantTypingIndicator
import app.roamsocket.android.ui.chat.ThinkingBlock
import app.roamsocket.android.ui.chat.ThinkingExtractor
import app.roamsocket.android.ui.markdown.MarkdownText
import app.roamsocket.android.ui.settings.ServerPairingSheet
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.server.Endpoint
import kotlinx.coroutines.launch

/**
 * Live session transcript + composer. Mirrors `ios/.../SessionView.swift`
 * (the chat-bubble transcript, status pill, permission sheet, PR sheet)
 * but stops short of the file browser, terminal, and tunnel UI.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionScreen(
    config: SessionConfig,
    paired: PairedServer,
    onBack: () -> Unit,
    viewModel: SessionViewModel = androidx.lifecycle.viewmodel.compose.viewModel(
        factory = SessionViewModel.factory(
            config = config,
            paired = SessionViewModel.PairedServerSnapshot(
                endpoint = paired.endpoint,
                token = paired.token,
                serverName = paired.serverName,
            ),
        ),
    ),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()
    val appContainer = LocalAppContainer.current
    val pairedServerStore: PairedServerStore = remember(appContainer) { appContainer.pairedServerStore }
    val scope = rememberCoroutineScope()

    // Workspace sheets — pick exactly one at a time so they don't stack.
    // Mirrors the iOS `showTerminal` / `showFiles` / `showPorts` / `showGitSheet`
    // state in `SessionView`.
    var showTerminalSheet by remember { mutableStateOf(false) }
    var showFilesSheet by remember { mutableStateOf(false) }
    var showPortsSheet by remember { mutableStateOf(false) }
    var showGitSheet by remember { mutableStateOf(false) }
    var pendingGitAction by remember { mutableStateOf<GitAction?>(null) }
    var openFile by remember { mutableStateOf<Pair<String, Boolean>?>(null) }
    var showRePairSheet by remember { mutableStateOf(false) }
    var workspaceMenuExpanded by remember { mutableStateOf(false) }

    // Track the token snapshot the pairing sheet was opened with so we
    // only re-connect when pairing actually produced a new token.
    val pairTokenAtOpen = remember { mutableStateOf(paired.token) }

    // Auto-prompt for re-pair when the session surfaces `needsRePair`
    // (e.g. desktop rejected the saved token). Mirrors the iOS
    // `.onChange(of: model.needsRePair)` → `presentPairingSheet()` hook.
    LaunchedEffect(state.needsRePair) {
        if (state.needsRePair) {
            pairTokenAtOpen.value = paired.token
            showRePairSheet = true
        }
    }

    val endpoint = remember(paired.endpoint) { Endpoint.fromHost(paired.endpoint) }

    // Slash-command suggestions while the composer is mid-`/goal …`.
    // Mirrors iOS `SessionView.slashCommands` / `slashSuggestions`. The
    // tap inserts the full token into the draft.
    val slashSuggestions: List<SlashCommand> = remember(state.draft) {
        val t = state.draft.trimStart()
        if (!t.startsWith("/") || state.draft.contains('\n')) emptyList()
        else SLASH_COMMANDS.filter { c ->
            c.token.startsWith(t, ignoreCase = true) ||
                (t.startsWith("/g") && c.token.startsWith("/goal", ignoreCase = true))
        }
    }
    val showSlashMenu by remember {
        derivedStateOf { state.isSessionReady && slashSuggestions.isNotEmpty() && state.draft.trimStart().startsWith("/") }
    }

    LaunchedEffect(state.transcript.size, state.isRunning) {
        if (state.transcript.isNotEmpty()) {
            listState.animateScrollToItem(state.transcript.size - 1)
        }
    }

    Column(modifier = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        TopAppBar(
            title = {
                Column {
                    Text(
                        text = config.repo.fullName,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = state.connectionStatusLine ?: "",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            navigationIcon = {
                IconButton(onClick = {
                    viewModel.disconnect()
                    onBack()
                }) {
                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
                }
            },
            actions = {
                // Diff stats badge — iOS mirrors the same `+N −M` chip
                // in the top bar so the user can see total local change
                // at a glance.
                if (state.hasDiffs) {
                    val stats = state.totalDiffStats
                    Text(
                        text = "+${stats.added} -${stats.removed}",
                        style = MaterialTheme.typography.bodySmall.copy(
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.SemiBold,
                        ),
                        color = Palette.Accent,
                        modifier = Modifier.padding(end = 4.dp),
                    )
                }
                // Tasks progress chip — iOS uses a checklist + ratio.
                if (state.hasAgentTasks) {
                    val progress = state.taskProgress
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(end = 8.dp),
                    ) {
                        Text(
                            text = "${progress.done}/${progress.total}",
                            style = MaterialTheme.typography.bodySmall.copy(
                                fontFamily = FontFamily.Monospace,
                                fontWeight = FontWeight.SemiBold,
                            ),
                            color = Palette.Accent,
                        )
                    }
                }
                if (state.isRunning) {
                    IconButton(onClick = viewModel::interrupt) {
                        Icon(Icons.Outlined.Stop, contentDescription = "Interrupt")
                    }
                } else {
                    // `Finish · PR` chip: tap to open the git sheet for
                    // review, long-press to instantly commit + push +
                    // open PR with an auto-generated subject. Mirrors
                    // iOS `SessionView.finishWithPR` invoked from the
                    // long-press on "Done".
                    Box {
                        var chipPressed by remember { mutableStateOf(false) }
                        AssistChip(
                            onClick = {
                                pendingGitAction = GitAction.All
                                showGitSheet = true
                            },
                            label = {
                                Text(if (state.prUrl != null) "View PR" else "Finish · PR")
                            },
                            enabled = state.isSessionReady,
                        )
                        // Overlay an invisible long-press target on
                        // the chip so a long-press anywhere on it
                        // calls `finishWithPR` without opening the
                        // git sheet.
                        Box(
                            modifier = Modifier
                                .matchParentSize()
                                .pointerInput(Unit) {
                                    detectTapGestures(
                                        onLongPress = {
                                            if (state.isSessionReady) {
                                                viewModel.finishWithPR()
                                                chipPressed = true
                                            }
                                        },
                                    )
                                },
                        )
                    }
                }
                // Workspace menu (mirrors iOS `Menu` in the top bar).
                val context = LocalContext.current
                Box {
                    IconButton(onClick = { workspaceMenuExpanded = true }) {
                        Icon(Icons.Outlined.Menu, contentDescription = "Workspace menu")
                    }
                    androidx.compose.material3.DropdownMenu(
                        expanded = workspaceMenuExpanded,
                        onDismissRequest = { workspaceMenuExpanded = false },
                    ) {
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text("Shell") },
                            leadingIcon = { Icon(Icons.Outlined.Terminal, contentDescription = null) },
                            enabled = endpoint != null && state.isSessionReady,
                            onClick = {
                                workspaceMenuExpanded = false
                                showTerminalSheet = true
                            },
                        )
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text("Files") },
                            leadingIcon = { Icon(Icons.Outlined.Description, contentDescription = null) },
                            enabled = endpoint != null && state.isSessionReady,
                            onClick = {
                                workspaceMenuExpanded = false
                                showFilesSheet = true
                            },
                        )
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text("Open ports") },
                            leadingIcon = { Icon(Icons.Outlined.NetworkCheck, contentDescription = null) },
                            enabled = endpoint != null && state.isSessionReady,
                            onClick = {
                                workspaceMenuExpanded = false
                                showPortsSheet = true
                            },
                        )
                        // Auto-preview: refresh ports, pick the first
                        // web-shaped port, tunnel it, open the public
                        // URL in the system browser. Mirrors iOS
                        // `openBrowserPreview` in the workspace menu.
                        androidx.compose.material3.DropdownMenuItem(
                            text = {
                                Text(
                                    if (state.isBrowserBusy) "Opening preview…" else "Browser",
                                )
                            },
                            leadingIcon = { Icon(Icons.Outlined.Link, contentDescription = null) },
                            enabled = endpoint != null && state.isSessionReady && !state.isBrowserBusy,
                            onClick = {
                                workspaceMenuExpanded = false
                                viewModel.openBrowserPreview(
                                    onUrl = { url ->
                                        if (url != null) openSystemBrowser(context, url)
                                    },
                                )
                            },
                        )
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text("Commit") },
                            leadingIcon = { Icon(Icons.Outlined.Check, contentDescription = null) },
                            enabled = state.isSessionReady,
                            onClick = {
                                workspaceMenuExpanded = false
                                pendingGitAction = GitAction.Commit
                                showGitSheet = true
                            },
                        )
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text("Re-pair…") },
                            leadingIcon = { Icon(Icons.Outlined.Link, contentDescription = null) },
                            onClick = {
                                workspaceMenuExpanded = false
                                pairTokenAtOpen.value = paired.token
                                showRePairSheet = true
                            },
                        )
                    }
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = MaterialTheme.colorScheme.surface,
                titleContentColor = MaterialTheme.colorScheme.onSurface,
            ),
        )

        state.error?.let { err ->
            ErrorRow(message = err, onDismiss = viewModel::dismissError)
        }

        // Re-pair CTA — the iOS sheet is auto-presented on `needsRePair`
        // but we also surface a manual "Enter pairing code" button in the
        // error row when the token is bad.
        if (state.needsRePair) {
            Surface(
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .clickable {
                        pairTokenAtOpen.value = paired.token
                        showRePairSheet = true
                    },
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Link,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onError,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = "Desktop rejected the pairing token. Tap to re-pair.",
                        color = MaterialTheme.colorScheme.onError,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }
        }

        if (state.prUrl != null) {
            PrBanner(url = state.prUrl!!, onDismiss = { /* keep around until next */ })
        }

        // Environment connection pill — iOS parity.
        EnvironmentConnectionPill(
            environment = config.environment,
            connectionPath = if (state.connectionStatusLine?.startsWith("Re-pair", ignoreCase = true) == true) {
                ConnectionPath.Offline
            } else if (state.isSessionReady) {
                ConnectionPath.Local
            } else {
                ConnectionPath.Offline
            },
        )

        // Mirrors the iOS banner stack: goal → model status → agent
        // tasks. Banners are mutually independent so a session can
        // show all three at once.
        if (state.showsGoalBanner) {
            GoalBanner(
                goal = state.goalStatus!!,
                hasActiveGoal = state.hasActiveGoal,
                onClear = { viewModel.send("/goal clear") },
            )
        }
        state.modelStatus?.let { ms ->
            ModelStatusBanner(status = ms)
        }
        if (state.hasAgentTasks) {
            AgentTasksBanner(
                progress = state.taskProgress,
                tasks = state.agentTasks,
            )
        }

        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(vertical = 12.dp, horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (state.transcript.isEmpty()) {
                item("empty") {
                    Text(
                        text = "Waiting for the desktop agent to start…",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 32.dp),
                    )
                }
            }
            items(state.transcript, key = { it.key() }) { item ->
                TranscriptRow(item = item, isRunning = state.isRunning)
            }
            // Live typing indicator while the agent is mid-turn and
            // nothing else at the tail of the transcript already
            // signals progress (matches iOS
            // `shouldShowTypingIndicator`).
            if (shouldShowTypingIndicator(state)) {
                item("running") {
                    AssistantTypingIndicator(
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
                    )
                }
            }
        }

        if (state.queuedMessage.isNotBlank()) {
            Text(
                text = "Queued: ${state.queuedMessage}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }

        if (showSlashMenu) {
            SlashCommandMenu(
                suggestions = slashSuggestions,
                onSelect = { token ->
                    viewModel.updateDraft(if (token.endsWith(' ')) token else "$token ")
                },
            )
        }

        Composer(
            draft = state.draft,
            enabled = state.isSessionReady,
            onDraftChange = viewModel::updateDraft,
            onSend = { viewModel.send(state.draft) },
        )
    }

    state.pendingPermission?.let { perm ->
        PermissionDialog(permission = perm, onDecision = viewModel::respondPermission)
    }

    // Workspace sheets (iOS parity). Terminal / Files / Open ports
    // use the partial-expand detent so the user can drag them down
    // to peek at the transcript. FileViewer + GitSheet open fully
    // expanded — the editor and form need the full height.
    if (showTerminalSheet && endpoint != null) {
        SheetContainer(onDismiss = { showTerminalSheet = false }, title = "Shell") {
            TerminalPane(
                sessionId = state.sessionId ?: "",
                endpoint = endpoint,
                token = paired.token,
            )
        }
    }
    if (showFilesSheet && endpoint != null) {
        SheetContainer(onDismiss = { showFilesSheet = false }, title = "Files") {
            FileExplorerPane(
                sessionId = state.sessionId ?: "",
                endpoint = endpoint,
                token = paired.token,
                onOpenFile = { path, preferDiff ->
                    openFile = path to preferDiff
                },
            )
        }
    }
    openFile?.let { (path, preferDiff) ->
        if (endpoint != null) {
            SheetContainer(
                onDismiss = { openFile = null },
                title = path.substringAfterLast('/'),
                startExpanded = true,
            ) {
                FileViewerPane(
                    sessionId = state.sessionId ?: "",
                    path = path,
                    endpoint = endpoint,
                    token = paired.token,
                    preferDiff = preferDiff,
                    onClose = { openFile = null },
                )
            }
        } else {
            openFile = null
        }
    }
    if (showPortsSheet && endpoint != null) {
        SheetContainer(onDismiss = { showPortsSheet = false }, title = "Open ports") {
            PortManagerPane(
                sessionId = state.sessionId ?: "",
                endpoint = endpoint,
                token = paired.token,
            )
        }
    }
    if (showGitSheet && pendingGitAction != null) {
        SheetContainer(
            onDismiss = { showGitSheet = false; pendingGitAction = null },
            title = pendingGitAction!!.title,
            startExpanded = true,
        ) {
            GitSheet(
                action = pendingGitAction!!,
                sessionId = state.sessionId ?: "",
                endpoint = endpoint,
                token = paired.token,
                firstUserMessage = state.firstUserMessage,
                transcript = state.transcript.map { it.toPersisted() },
                diffSummary = null,
                diffStats = state.totalDiffStats,
                onDismiss = { showGitSheet = false; pendingGitAction = null },
                onPublished = { _ ->
                    showGitSheet = false
                    pendingGitAction = null
                },
            )
        }
    }
    if (showRePairSheet) {
        ServerPairingSheet(
            initialHost = paired.endpoint,
            initialCode = "",
            title = "Re-pair desktop",
            description = "Open the desktop server, then type the 6-character code shown there.",
            showCancel = true,
            onDismiss = { showRePairSheet = false },
            onPaired = { server ->
                showRePairSheet = false
                // Persist the re-paired server so Settings + the
                // sidebar continue to point at the new token /
                // server name after this session ends. The
                // SessionViewModel then swaps its snapshot and
                // reconnects.
                scope.launch { pairedServerStore.save(server) }
                if (server.token != pairTokenAtOpen.value) {
                    viewModel.applyRePair(
                        endpoint = server.endpoint,
                        token = server.token,
                        serverName = server.serverName,
                    )
                }
            },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SheetContainer(
    onDismiss: () -> Unit,
    title: String,
    startExpanded: Boolean = false,
    content: @Composable () -> Unit,
) {
    // Mirrors the iOS `.sheet` + `.presentationDetents([.medium, .large])`
    // UX. Android's `ModalBottomSheet` doesn't have a "medium" detent
    // exactly, so we ship two values: partial (≈ 50% of the screen) for
    // sheets the user might want to glance at while reading, and
    // expanded (full) for file editors and the terminal.
    val sheetState = androidx.compose.material3.rememberModalBottomSheetState(
        skipPartiallyExpanded = startExpanded,
    )
    LaunchedEffect(Unit) {
        if (startExpanded) sheetState.expand() else sheetState.partialExpand()
    }
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.background,
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.Surface)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                TextButton(onClick = onDismiss) { Text("Done") }
                Spacer(Modifier.weight(1f))
                Text(
                    text = title,
                    color = Palette.TextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.weight(1f))
                // Spacer to keep the title centred (matches Done width).
                TextButton(onClick = {}, enabled = false) { Text("Done") }
            }
            content()
        }
    }
}

/**
 * True while the agent is mid-turn and nothing else at the tail of the
 * transcript already signals progress (live assistant text, thinking
 * row, or an in-flight tool card). Mirrors the iOS
 * `shouldShowTypingIndicator` computed property.
 */
private fun shouldShowTypingIndicator(state: SessionUiState): Boolean {
    if (!state.isRunning) return false
    // A live model_status banner is already a progress signal.
    if (state.modelStatus != null) return false
    val last = state.transcript.lastOrNull() ?: return true
    return when (last) {
        is TranscriptItem.User, is TranscriptItem.Diff -> true
        is TranscriptItem.Assistant -> {
            val parsed = ThinkingExtractor.extract(last.text)
            val cleaned = ThinkingExtractor.stripControlTokens(parsed.content)
                .let { ThinkingExtractor.stripToolCallXml(it) }
            // Visible body or any thinking already shows progress.
            if (cleaned.isNotBlank()) return false
            if (parsed.thinking != null) return false
            true
        }
        is TranscriptItem.Tool -> last.ok != null
    }
}

@Composable
private fun TranscriptRow(item: TranscriptItem, isRunning: Boolean) {
    when (item) {
        is TranscriptItem.User -> UserBubble(item.text)
        is TranscriptItem.Assistant -> AssistantBubble(item.text, isRunning = isRunning)
        is TranscriptItem.Tool -> ToolCard(item)
        is TranscriptItem.Diff -> DiffRow(item)
    }
}

@Composable
private fun UserBubble(text: String) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Surface(
            color = MaterialTheme.colorScheme.primary,
            shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp, bottomStart = 16.dp, bottomEnd = 4.dp),
            modifier = Modifier.padding(horizontal = 4.dp),
        ) {
            Text(
                text = text,
                color = MaterialTheme.colorScheme.onPrimary,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            )
        }
    }
}

@Composable
private fun AssistantBubble(text: String, isRunning: Boolean) {
    if (text.isEmpty()) return
    // Parity with iOS `SessionAssistantMessage`: pull `<think>` blocks
    // out via [ThinkingExtractor] and render the body as Markwon
    // markdown (same MarkdownText the chat uses).
    val parsed = ThinkingExtractor.extract(text)
    val cleaned = ThinkingExtractor
        .stripControlTokens(parsed.content)
        .let { ThinkingExtractor.stripToolCallXml(it) }
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
        parsed.thinking?.let { thinking ->
            ThinkingBlock(text = thinking)
            Spacer(Modifier.size(8.dp))
        }
        if (cleaned.isNotBlank()) {
            MarkdownText(markdown = cleaned, fontSize = 16.sp)
        }
        if (isRunning && parsed.thinking == null && cleaned.isBlank()) {
            Spacer(Modifier.size(4.dp))
            AssistantTypingIndicator()
        }
    }
}

/**
 * Collapsible tool-call card. Summary row is always visible; command
 * output stays collapsed until the user taps to expand. Mirrors the
 * iOS `ToolCard` in `SessionView.swift`.
 */
@Composable
private fun ToolCard(item: TranscriptItem.Tool) {
    var expanded by remember { mutableStateOf(false) }
    val hasOutput = !item.output.isNullOrEmpty()
    val (statusIcon, statusTint) = when (item.ok) {
        null -> Icons.Outlined.DataObject to Palette.TextSecondary
        true -> Icons.Outlined.Check to Palette.Success
        false -> Icons.Outlined.Cancel to Palette.Danger
    }
    val rotation by animateFloatAsState(
        targetValue = if (expanded) 90f else 0f,
        animationSpec = tween(durationMillis = 180),
        label = "tool-chevron",
    )
    Surface(
        color = Palette.Surface,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(6.dp))
                    .clickable {
                        if (hasOutput) expanded = !expanded
                    },
            ) {
                Icon(
                    imageVector = statusIcon,
                    contentDescription = null,
                    tint = statusTint,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = item.summary.ifBlank { item.tool },
                    style = MaterialTheme.typography.bodySmall.copy(
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Medium,
                    ),
                    color = Palette.TextPrimary,
                    maxLines = if (expanded) Int.MAX_VALUE else 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (hasOutput) {
                    Icon(
                        imageVector = Icons.Outlined.ChevronRight,
                        contentDescription = if (expanded) "Collapse output" else "Expand output",
                        tint = Palette.TextTertiary,
                        modifier = Modifier
                            .size(14.dp)
                            .rotate(rotation),
                    )
                }
            }
            AnimatedVisibility(visible = expanded && hasOutput) {
                Text(
                    text = item.output.orEmpty().take(2_000),
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    color = Palette.TextSecondary,
                    modifier = Modifier
                        .padding(top = 8.dp)
                        .heightIn(max = 200.dp),
                )
            }
        }
    }
}

@Composable
private fun DiffRow(item: TranscriptItem.Diff) {
    val color = if (item.added > 0 && item.removed == 0) MaterialTheme.colorScheme.primary
                else if (item.removed > 0 && item.added == 0) MaterialTheme.colorScheme.error
                else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = item.path,
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            modifier = Modifier.weight(1f),
        )
        Text(
            text = "+${item.added} -${item.removed}",
            style = MaterialTheme.typography.bodySmall,
            color = color,
        )
    }
}

@Composable
private fun Composer(
    draft: String,
    enabled: Boolean,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 2.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = draft,
                onValueChange = onDraftChange,
                modifier = Modifier.weight(1f),
                placeholder = { Text(if (enabled) "Send a message…" else "Waiting for session…") },
                enabled = enabled,
                singleLine = false,
                maxLines = 4,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.Sentences,
                    imeAction = ImeAction.Send,
                ),
            )
            IconButton(onClick = onSend, enabled = enabled && draft.isNotBlank()) {
                Icon(Icons.AutoMirrored.Outlined.Send, contentDescription = "Send")
            }
        }
    }
}

@Composable
private fun PermissionDialog(permission: PendingPermission, onDecision: (Boolean) -> Unit) {
    AlertDialog(
        onDismissRequest = { onDecision(false) },
        icon = { Icon(Icons.Outlined.QuestionMark, contentDescription = null) },
        title = { Text("Allow ${permission.tool}?") },
        text = {
            Text(
                text = permission.summary,
                style = MaterialTheme.typography.bodyMedium,
            )
        },
        confirmButton = {
            TextButton(onClick = { onDecision(true) }) {
                Icon(Icons.Outlined.Check, contentDescription = null)
                Text(" Allow")
            }
        },
        dismissButton = {
            OutlinedButton(onClick = { onDecision(false) }) {
                Icon(Icons.Outlined.Cancel, contentDescription = null)
                Text(" Deny")
            }
        },
    )
}

@Composable
private fun PrBanner(url: String, onDismiss: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "PR opened: $url",
                color = MaterialTheme.colorScheme.onPrimary,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onDismiss) {
                Text("Dismiss", color = MaterialTheme.colorScheme.onPrimary)
            }
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
                Icon(Icons.Outlined.Cancel, contentDescription = "Dismiss", tint = MaterialTheme.colorScheme.onError)
            }
        }
    }
}

private fun TranscriptItem.key(): String = when (this) {
    is TranscriptItem.User -> "u:" + text.hashCode()
    is TranscriptItem.Assistant -> "a:" + text.hashCode()
    is TranscriptItem.Tool -> "t:" + id
    is TranscriptItem.Diff -> "d:" + id
}

// MARK: - Banners (parity with iOS `goalBanner` / `modelLoadingBanner`
//  / `agentTasksBanner`).

@Composable
private fun GoalBanner(
    goal: GoalStatusUi,
    hasActiveGoal: Boolean,
    onClear: () -> Unit,
) {
    Surface(
        color = Palette.SurfaceElevated,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            Text(
                text = "◎",
                color = Palette.Accent,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(end = 8.dp, top = 2.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = if (goal.state == app.roamsocket.core.protocol.GoalState.ACHIEVED) "Goal achieved" else "/goal active",
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.TextPrimary,
                )
                if (!goal.condition.isNullOrBlank()) {
                    Text(
                        text = goal.condition,
                        style = MaterialTheme.typography.bodySmall,
                        color = Palette.TextSecondary,
                        maxLines = 2,
                    )
                }
                if (!goal.reason.isNullOrBlank()) {
                    Text(
                        text = goal.reason,
                        style = MaterialTheme.typography.bodySmall,
                        color = Palette.TextTertiary,
                        maxLines = 2,
                    )
                }
            }
            if (hasActiveGoal) {
                TextButton(onClick = onClear) {
                    Text(
                        "Clear",
                        color = Palette.Accent,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
    }
}

@Composable
private fun ModelStatusBanner(status: ModelStatusUi) {
    Surface(
        color = Palette.SurfaceElevated,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(14.dp),
                strokeWidth = 1.5.dp,
                color = Palette.Accent,
            )
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = if (status.isLoading) "Loading model…" else "Generating…",
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.TextPrimary,
                )
                val detail = status.message?.takeIf { it.isNotBlank() }
                    ?: status.hubId?.takeIf { it.isNotBlank() }
                if (detail != null) {
                    Text(
                        text = detail,
                        style = MaterialTheme.typography.bodySmall.copy(
                            fontFamily = if (status.hubId != null && status.message.isNullOrBlank())
                                FontFamily.Monospace else FontFamily.Default,
                        ),
                        color = Palette.TextTertiary,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

@Composable
private fun AgentTasksBanner(
    progress: TaskProgress,
    tasks: List<app.roamsocket.core.protocol.AgentTaskItem>,
) {
    var expanded by remember { mutableStateOf(false) }
    val fraction = progress.fraction
    val active = tasks.firstOrNull { it.status == app.roamsocket.core.protocol.AgentTaskStatus.IN_PROGRESS }
    Surface(
        color = Palette.SurfaceElevated,
        modifier = Modifier
            .fillMaxWidth()
            .clickable { expanded = !expanded },
    ) {
        Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "✓",
                    color = Palette.Accent,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "Tasks",
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.TextPrimary,
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "${progress.done}/${progress.total}",
                    style = MaterialTheme.typography.bodySmall.copy(
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.SemiBold,
                    ),
                    color = Palette.TextSecondary,
                )
                Spacer(Modifier.weight(1f))
                Icon(
                    imageVector = Icons.Outlined.ChevronRight,
                    contentDescription = if (expanded) "Collapse tasks" else "Expand tasks",
                    tint = Palette.TextTertiary,
                    modifier = Modifier
                        .size(14.dp)
                        .rotate(if (expanded) 90f else 0f),
                )
            }
            Spacer(Modifier.height(6.dp))
            LinearProgressIndicator(
                progress = { fraction },
                color = Palette.Accent,
                trackColor = Palette.Divider,
                modifier = Modifier.fillMaxWidth(),
            )
            if (active != null && !expanded) {
                Spacer(Modifier.height(6.dp))
                Text(
                    text = active.content,
                    style = MaterialTheme.typography.bodySmall,
                    color = Palette.TextSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            AnimatedVisibility(visible = expanded) {
                Column(modifier = Modifier.padding(top = 6.dp)) {
                    tasks.forEach { task ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(vertical = 2.dp),
                        ) {
                            val (mark, tint) = when (task.status) {
                                app.roamsocket.core.protocol.AgentTaskStatus.COMPLETED -> "✓" to Palette.Success
                                app.roamsocket.core.protocol.AgentTaskStatus.IN_PROGRESS -> "•" to Palette.Accent
                                app.roamsocket.core.protocol.AgentTaskStatus.CANCELLED -> "–" to Palette.TextTertiary
                                app.roamsocket.core.protocol.AgentTaskStatus.PENDING -> "·" to Palette.TextTertiary
                            }
                            Text(
                                text = mark,
                                color = tint,
                                fontSize = 13.sp,
                                modifier = Modifier.width(16.dp),
                            )
                            Text(
                                text = task.content,
                                style = MaterialTheme.typography.bodySmall,
                                color = if (task.status == app.roamsocket.core.protocol.AgentTaskStatus.COMPLETED)
                                    Palette.TextTertiary else Palette.TextSecondary,
                                textDecoration = if (task.status == app.roamsocket.core.protocol.AgentTaskStatus.COMPLETED)
                                    androidx.compose.ui.text.style.TextDecoration.LineThrough else null,
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Slash commands

private data class SlashCommand(val token: String, val detail: String)

private val SLASH_COMMANDS: List<SlashCommand> = listOf(
    SlashCommand("/goal ", "Keep working until a condition is met"),
    SlashCommand("/goal", "Show current goal status"),
    SlashCommand("/goal clear", "Clear the active goal"),
)

@Composable
private fun SlashCommandMenu(
    suggestions: List<SlashCommand>,
    onSelect: (String) -> Unit,
) {
    Surface(
        color = Palette.SurfaceElevated,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp),
    ) {
        Column {
            suggestions.forEach { cmd ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onSelect(cmd.token) }
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                ) {
                    Text(
                        text = cmd.token,
                        style = MaterialTheme.typography.bodyMedium.copy(
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.SemiBold,
                        ),
                        color = Palette.Accent,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        text = cmd.detail,
                        style = MaterialTheme.typography.bodyMedium,
                        color = Palette.TextSecondary,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

/**
 * Open [url] in the system browser. Best-effort — if no Activity
 * can handle the intent (e.g. the desktop returned a non-http URL)
 * the exception is swallowed.
 */
private fun openSystemBrowser(context: android.content.Context, url: String) {
    runCatching {
        val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }
}
