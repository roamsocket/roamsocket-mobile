package app.roamsocket.android.ui.browser

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.Bookmarks
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material.icons.outlined.Tab
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.LocalAppContainer
import app.roamsocket.android.ui.LocalNavigateToSettings
import app.roamsocket.android.ui.LocalOpenSidebar
import app.roamsocket.core.providers.AIModel

/**
 * Top-level browser screen. Mirrors the iOS `BrowserHomeView` (in
 * `ios/App/Sources/Features/Browser/BrowserView.swift`) 1:1 — same
 * top bar (menu + title + model pill + share), same bottom chrome
 * (plan approval / running banner / ask chat / AI bar / address bar /
 * nav toolbar), and the same Safari-style tab switcher.
 */
@Composable
fun BrowserHomeView(
    store: BrowserStore,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val openSidebar = LocalOpenSidebar.current
    val navigateToSettings = LocalNavigateToSettings.current

    val tabs by store.tabs.collectAsState()
    val activeTabId by store.activeTabId.collectAsState()
    val activeTab = remember(tabs, activeTabId) { tabs.firstOrNull { it.id == activeTabId } }

    val promptText by store.promptText.collectAsState()
    val promptMode by store.promptMode.collectAsState()
    val addressText by store.addressText.collectAsState()
    val pendingPlan by store.pendingPlan.collectAsState()
    val pendingStepsApproval by store.pendingStepsApproval.collectAsState()
    val runningPlan by store.runningPlan.collectAsState()
    val isPlanRunning by store.isPlanRunning.collectAsState()
    val isPlanning by store.isPlanning.collectAsState()
    val isAsking by store.isAsking.collectAsState()
    val isDecidingNextStep by store.isDecidingNextStep.collectAsState()
    val chatMessages by store.chatMessages.collectAsState()
    val errorMessage by store.errorMessage.collectAsState()
    val completionSummary by store.completionSummary.collectAsState()
    val completionOutcome by store.completionOutcome.collectAsState()
    val showTabsSheet by store.showTabsSheet.collectAsState()
    val showBookmarksSheet by store.showBookmarksSheet.collectAsState()
    val showModelPicker by store.showModelPicker.collectAsState()
    val bookmarks by store.bookmarks.collectAsState()
    val history by store.history.collectAsState()
    val selectedModel by store.selectedModel.collectAsState()

    var askChatExpanded by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(isAsking) {
        if (isAsking) askChatExpanded = true
    }

    val onOpenSidebar: () -> Unit = { openSidebar() }
    val onPageFinished: (BrowserTabState) -> Unit = { store.onPageFinished(it) }

    Surface(modifier = modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(modifier = Modifier.fillMaxSize()) {
            TopBar(
                title = activeTab?.title?.value?.takeIf { it.isNotEmpty() } ?: "Browser",
                activeUrl = activeTab?.urlString?.value.orEmpty(),
                selectedModelName = selectedModel?.let { AIModel.prettifiedDisplayName(it.modelID) }.orEmpty(),
                onMenu = onOpenSidebar,
                onShare = {
                    val url = activeTab?.urlString?.value.orEmpty()
                    if (url.isNotEmpty()) shareUrl(context, url)
                },
                onModelPill = { store.setShowModelPicker(true) },
                onAddModel = { navigateToSettings() },
            )
            // Content
            Box(modifier = Modifier.weight(1f)) {
                val url = activeTab?.urlString?.value.orEmpty()
                if (activeTab != null && url.isNotEmpty()) {
                    val isLoading = activeTab.isLoading.collectAsState().value
                    val progress = activeTab.estimatedProgress.collectAsState().value.toFloat().coerceIn(0.05f, 1f)
                    Box(modifier = Modifier.fillMaxSize()) {
                        BrowserWebView(
                            tab = activeTab,
                            onPageFinished = onPageFinished,
                            modifier = Modifier.fillMaxSize(),
                        )
                        if (isLoading) {
                            LinearProgressIndicator(
                                progress = { progress },
                                modifier = Modifier.fillMaxWidth().height(2.dp),
                                color = MaterialTheme.colorScheme.primary,
                            )
                        }
                    }
                } else {
                    EmptyState(
                        bookmarks = bookmarks,
                        onOpenBookmark = { store.openBookmark(it) },
                    )
                }
            }
            BottomChrome(
                store = store,
                activeTab = activeTab,
                promptText = promptText,
                promptMode = promptMode,
                addressText = addressText,
                pendingPlan = pendingPlan,
                pendingStepsApproval = pendingStepsApproval,
                runningPlan = runningPlan,
                isPlanRunning = isPlanRunning,
                isPlanning = isPlanning,
                isAsking = isAsking,
                isDecidingNextStep = isDecidingNextStep,
                chatMessages = chatMessages,
                errorMessage = errorMessage,
                completionSummary = completionSummary,
                completionOutcome = completionOutcome,
                askChatExpanded = askChatExpanded,
                onToggleAskChat = { askChatExpanded = !askChatExpanded },
            )
        }
    }

    if (showTabsSheet) {
        TabsSwitcherSheet(
            store = store,
            onDismiss = { store.setShowTabsSheet(false) },
        )
    }
    if (showBookmarksSheet) {
        BookmarksSheet(
            store = store,
            bookmarks = bookmarks,
            history = history,
            onDismiss = { store.setShowBookmarksSheet(false) },
        )
    }
    if (showModelPicker) {
        ModelPickerSheet(
            currentModel = selectedModel,
            onSelect = {
                store.setSelectedModel(it)
                store.setShowModelPicker(false)
            },
            onAddModel = {
                store.setShowModelPicker(false)
                navigateToSettings()
            },
            onDismiss = { store.setShowModelPicker(false) },
        )
    }
}

@Composable
private fun TopBar(
    title: String,
    activeUrl: String,
    selectedModelName: String,
    onMenu: () -> Unit,
    onShare: () -> Unit,
    onModelPill: () -> Unit,
    onAddModel: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.background)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        IconButton(
            onClick = onMenu,
            modifier = Modifier.size(34.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant),
        ) {
            Icon(
                imageVector = Icons.Outlined.SwapHoriz,
                contentDescription = "Menu",
                tint = MaterialTheme.colorScheme.onSurface,
            )
        }
        Text(
            text = title,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (selectedModelName.isEmpty()) {
            AssistChip(
                onClick = onAddModel,
                label = { Text("Add a model", fontSize = 12.sp) },
                colors = AssistChipDefaults.assistChipColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    labelColor = MaterialTheme.colorScheme.onPrimaryContainer,
                ),
            )
        } else {
            AssistChip(
                onClick = onModelPill,
                label = { Text(selectedModelName, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            )
        }
        if (activeUrl.isNotEmpty()) {
            IconButton(
                onClick = onShare,
                modifier = Modifier.size(34.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant),
            ) {
                Icon(
                    imageVector = Icons.Outlined.Bookmarks,
                    contentDescription = "Share",
                    tint = MaterialTheme.colorScheme.onSurface,
                )
            }
        }
    }
}

@Composable
private fun EmptyState(
    bookmarks: List<BrowserBookmark>,
    onOpenBookmark: (BrowserBookmark) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Spacer(Modifier.weight(1f))
        Icon(
            imageVector = Icons.Filled.Public,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(48.dp),
        )
        Spacer(Modifier.size(16.dp))
        Text(
            text = "Browse the web, hands-free",
            fontSize = 21.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.size(8.dp))
        Text(
            text = "Type an address below, ask the AI a question about a page with Ask, or tell it to do something — it always shows its plan before acting.",
            fontSize = 14.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 12.dp),
        )
        if (bookmarks.isNotEmpty()) {
            Spacer(Modifier.size(24.dp))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(bookmarks.take(8), key = { it.id }) { bookmark ->
                    AssistChip(
                        onClick = { onOpenBookmark(bookmark) },
                        label = { Text(bookmark.title.ifEmpty { bookmark.url }, fontSize = 12.sp) },
                    )
                }
            }
        }
        Spacer(Modifier.weight(1f))
    }
}

@Composable
private fun BottomChrome(
    store: BrowserStore,
    activeTab: BrowserTabState?,
    promptText: String,
    promptMode: BrowserPromptMode,
    addressText: String,
    pendingPlan: BrowserPlan?,
    pendingStepsApproval: List<BrowserStep>?,
    runningPlan: BrowserPlan?,
    isPlanRunning: Boolean,
    isPlanning: Boolean,
    isAsking: Boolean,
    isDecidingNextStep: Boolean,
    chatMessages: List<BrowserChatMessage>,
    errorMessage: String?,
    completionSummary: String?,
    completionOutcome: BrowserStore.CompletionOutcome,
    askChatExpanded: Boolean,
    onToggleAskChat: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .imePadding(),
    ) {
        // Plan approval / running / finished / error / ask chat (vertical stack)
        pendingPlan?.let { plan ->
            PlanApprovalCard(plan = plan, onDeny = store::denyPendingPlan, onBulk = store::approvePlanBulk, onStepByStep = store::approvePlanStepByStep)
        }
        pendingStepsApproval?.let { steps ->
            StepsApprovalCard(steps = steps, onDeny = { store.respondToPendingStep(allow = false) }, onAllow = { store.respondToPendingStep(allow = true) })
        }
        if (runningPlan != null && isPlanRunning) {
            RunningPlanBanner(
                plan = runningPlan,
                commentary = store.currentCommentary.collectAsState().value,
                isDecidingNextStep = isDecidingNextStep,
                onStop = store::stopRun,
            )
        }
        if (runningPlan != null && !isPlanRunning) {
            FinishedPlanBanner(
                plan = runningPlan,
                summary = completionSummary,
                outcome = completionOutcome,
                onDismiss = store::dismissRunningPlan,
            )
        }
        if (chatMessages.isNotEmpty()) {
            AskChatPanel(
                messages = chatMessages,
                isAsking = isAsking,
                expanded = askChatExpanded,
                onToggle = onToggleAskChat,
                onClear = store::clearChat,
            )
        }
        errorMessage?.let { msg ->
            ErrorBanner(message = msg, onDismiss = store::dismissError)
        }
        AiPromptBar(
            mode = promptMode,
            text = promptText,
            isBusy = isPlanning || isAsking || isPlanRunning,
            onModeChange = store::setPromptMode,
            onTextChange = store::updatePromptText,
            onSend = store::submitPrompt,
            onStop = store::stopRun,
        )
        AddressBar(
            text = addressText,
            onTextChange = store::updateAddressText,
            onSubmit = store::goToAddress,
        )
        BottomToolbar(
            activeTab = activeTab,
            onBack = { activeTab?.goBack() },
            onForward = { activeTab?.goForward() },
            onRefresh = { activeTab?.reload() },
            onBookmarks = { store.setShowBookmarksSheet(true) },
            onTabs = {
                store.refreshAllSnapshots()
                store.setShowTabsSheet(true)
            },
        )
    }
}

@Composable
private fun PlanApprovalCard(
    plan: BrowserPlan,
    onDeny: () -> Unit,
    onBulk: () -> Unit,
    onStepByStep: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = plan.goal,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = "${plan.steps.size} step${if (plan.steps.size == 1) "" else "s"}:",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        plan.steps.forEachIndexed { idx, step ->
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("${idx + 1}.", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(step.description, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurface)
            }
        }
        Spacer(Modifier.size(2.dp))
        Text(
            text = "These steps run in order below. After that, the AI re-checks the live page before proposing anything further — it may ask to run several more mechanical steps at once (like checking a row of boxes), but always shows them first.",
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.size(2.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            OutlinedButton(onClick = onDeny, modifier = Modifier.weight(1f)) { Text("Deny") }
            OutlinedButton(onClick = onStepByStep, modifier = Modifier.weight(1f)) { Text("Review each") }
            Button(onClick = onBulk, modifier = Modifier.weight(1f)) { Text("Run all") }
        }
    }
}

@Composable
private fun StepsApprovalCard(
    steps: List<BrowserStep>,
    onDeny: () -> Unit,
    onAllow: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            text = if (steps.size == 1) "Allow this step?" else "Allow these ${steps.size} steps?",
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        steps.forEach { step ->
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(
                    imageVector = stepIcon(step.kind),
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(14.dp),
                )
                Text(step.description, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurface)
            }
        }
        Spacer(Modifier.size(2.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            OutlinedButton(onClick = onDeny, modifier = Modifier.weight(1f)) { Text("Deny") }
            Button(
                onClick = onAllow,
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) {
                Text(if (steps.size == 1) "Allow" else "Allow all ${steps.size}")
            }
        }
    }
}

@Composable
private fun RunningPlanBanner(
    plan: BrowserPlan,
    commentary: String?,
    isDecidingNextStep: Boolean,
    onStop: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        val currentStep = plan.steps.lastOrNull { it.status == BrowserStep.Status.RUNNING }
        val label = currentStep?.description
            ?: if (isDecidingNextStep) "Deciding what to do next…" else "Working on it…"
        CircularProgressIndicator(
            modifier = Modifier.size(16.dp),
            strokeWidth = 2.dp,
            color = MaterialTheme.colorScheme.primary,
        )
        Text(
            text = label,
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        IconButton(
            onClick = onStop,
            modifier = Modifier
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surface)
                .size(28.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = "Stop",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(14.dp),
            )
        }
    }
    commentary?.takeIf { it.isNotEmpty() }?.let { c ->
        Text(
            text = c,
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 36.dp, vertical = 0.dp),
        )
    }
}

@Composable
private fun FinishedPlanBanner(
    plan: BrowserPlan,
    summary: String?,
    outcome: BrowserStore.CompletionOutcome,
    onDismiss: () -> Unit,
) {
    val anyFailed = plan.steps.any { it.status == BrowserStep.Status.FAILED }
    val (icon, tint, title) = when (outcome) {
        BrowserStore.CompletionOutcome.SUCCESS ->
            if (anyFailed) Triple(Icons.Filled.Close, Color(0xFFFFA000), "Plan finished with errors")
            else Triple(Icons.Filled.CheckCircle, Color(0xFF4CAF50), "Plan finished")
        BrowserStore.CompletionOutcome.BLOCKED ->
            Triple(Icons.Filled.Close, Color(0xFFFFA000), "Couldn't finish the task")
        BrowserStore.CompletionOutcome.STOPPED ->
            Triple(Icons.Filled.Stop, Color(0xFF9E9E9E), "Plan stopped")
    }
    Column(modifier = Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(imageVector = icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
                if (!summary.isNullOrEmpty()) {
                    Text(summary, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3)
                }
            }
            IconButton(
                onClick = onDismiss,
                modifier = Modifier.size(26.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surface),
            ) {
                Icon(imageVector = Icons.Filled.Close, contentDescription = "Dismiss", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(12.dp))
            }
        }
    }
}

@Composable
private fun AskChatPanel(
    messages: List<BrowserChatMessage>,
    isAsking: Boolean,
    expanded: Boolean,
    onToggle: () -> Unit,
    onClear: () -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.weight(1f).clickable(onClick = onToggle),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    imageVector = Icons.Filled.Public,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(14.dp),
                )
                Text("Ask · About this page", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (isAsking) {
                    CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 1.5.dp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            IconButton(onClick = onClear, modifier = Modifier.size(26.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant)) {
                Icon(imageVector = Icons.Filled.Close, contentDescription = "Clear", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(12.dp))
            }
        }
        if (expanded) {
            Column(modifier = Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                messages.forEach { msg ->
                    AskMessageRow(msg)
                }
            }
        }
    }
}

@Composable
private fun AskMessageRow(msg: BrowserChatMessage) {
    when (msg.role) {
        BrowserChatMessage.Role.USER -> {
            Text(
                text = msg.content,
                fontSize = 14.sp,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 48.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            )
        }
        BrowserChatMessage.Role.ASSISTANT -> {
            Text(
                text = msg.content,
                fontSize = 14.sp,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

@Composable
private fun ErrorBanner(message: String, onDismiss: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(imageVector = Icons.Filled.Close, contentDescription = null, tint = Color(0xFFFFA000))
        Text(message, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f), maxLines = 2)
        IconButton(onClick = onDismiss) { Icon(imageVector = Icons.Filled.Close, contentDescription = "Dismiss", tint = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun AiPromptBar(
    mode: BrowserPromptMode,
    text: String,
    isBusy: Boolean,
    onModeChange: (BrowserPromptMode) -> Unit,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Ask / Do toggle
        Row(
            modifier = Modifier.clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant).padding(2.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            ModePill(
                label = BrowserPromptMode.ASK.title,
                selected = mode == BrowserPromptMode.ASK,
                onClick = { onModeChange(BrowserPromptMode.ASK) },
            )
            ModePill(
                label = BrowserPromptMode.ACT.title,
                selected = mode == BrowserPromptMode.ACT,
                onClick = { onModeChange(BrowserPromptMode.ACT) },
            )
        }
        // Input
        val placeholder = if (mode == BrowserPromptMode.ASK)
            "Ask about this page…"
        else
            "Ask AI to do something on this page…"
        androidx.compose.material3.OutlinedTextField(
            value = text,
            onValueChange = onTextChange,
            placeholder = { Text(placeholder, fontSize = 14.sp) },
            modifier = Modifier.weight(1f),
            singleLine = true,
            enabled = !isBusy,
        )
        if (isBusy) {
            IconButton(onClick = onStop) {
                Icon(imageVector = Icons.Filled.Stop, contentDescription = "Stop", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else if (text.isNotBlank()) {
            IconButton(onClick = onSend) {
                Icon(imageVector = Icons.Filled.ArrowUpward, contentDescription = "Send", tint = MaterialTheme.colorScheme.primary)
            }
        }
    }
}

@Composable
private fun ModePill(label: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (selected) MaterialTheme.colorScheme.surface else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, fontSize = 12.sp, color = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun AddressBar(
    text: String,
    onTextChange: (String) -> Unit,
    onSubmit: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.Public,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(16.dp),
        )
        androidx.compose.material3.OutlinedTextField(
            value = text,
            onValueChange = onTextChange,
            placeholder = { Text("Search or type a URL", fontSize = 13.sp) },
            modifier = Modifier.weight(1f),
            singleLine = true,
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                imeAction = androidx.compose.ui.text.input.ImeAction.Go,
            ),
            keyboardActions = androidx.compose.foundation.text.KeyboardActions(onGo = { onSubmit() }),
        )
    }
}

@Composable
private fun BottomToolbar(
    activeTab: BrowserTabState?,
    onBack: () -> Unit,
    onForward: () -> Unit,
    onRefresh: () -> Unit,
    onBookmarks: () -> Unit,
    onTabs: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        val canBack = activeTab?.canGoBack?.collectAsState()?.value ?: false
        val canForward = activeTab?.canGoForward?.collectAsState()?.value ?: false
        val isLoading = activeTab?.isLoading?.collectAsState()?.value ?: false
        ToolbarButton(icon = Icons.AutoMirrored.Outlined.ArrowBack, label = "Back", enabled = canBack, onClick = onBack)
        ToolbarButton(icon = Icons.Filled.ArrowUpward, label = "Forward", enabled = canForward, onClick = onForward, rotateForward = true)
        ToolbarButton(
            icon = if (isLoading) Icons.Filled.Close else Icons.Filled.Refresh,
            label = if (isLoading) "Stop" else "Refresh",
            enabled = true,
            onClick = { if (isLoading) activeTab?.stop() else onRefresh() },
        )
        ToolbarButton(icon = Icons.Outlined.Bookmarks, label = "Bookmarks", onClick = onBookmarks)
        ToolbarButton(icon = Icons.Outlined.Tab, label = "Tabs", onClick = onTabs)
    }
}

@Composable
private fun ToolbarButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
    rotateForward: Boolean = false,
) {
    val tint = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier.clickable(enabled = enabled, onClick = onClick).padding(horizontal = 4.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = tint,
            modifier = Modifier
                .size(22.dp)
                .let { if (rotateForward) it.then(Modifier.graphicsLayer(rotationZ = 90f)) else it },
        )
        Text(label, fontSize = 10.sp, color = tint, maxLines = 1)
    }
}

private fun stepIcon(kind: BrowserStep.Kind): androidx.compose.ui.graphics.vector.ImageVector = when (kind) {
    BrowserStep.Kind.NAVIGATE -> Icons.Filled.ArrowUpward
    BrowserStep.Kind.CLICK -> Icons.Filled.Public // use touch fallback
    BrowserStep.Kind.TYPE -> Icons.Filled.Public
    BrowserStep.Kind.SCROLL -> Icons.Filled.Public
    BrowserStep.Kind.BACK -> Icons.AutoMirrored.Outlined.ArrowBack
    BrowserStep.Kind.FORWARD -> Icons.Filled.ArrowUpward
    BrowserStep.Kind.RELOAD -> Icons.Filled.Refresh
    BrowserStep.Kind.WAIT -> Icons.Filled.Close
    BrowserStep.Kind.EXTRACT -> Icons.Filled.Public
    BrowserStep.Kind.DISMISS_CONSENT -> Icons.Filled.Close
}

// (Modifier extensions imported from foundation.clickable and graphicsLayer above.)

private fun shareUrl(context: android.content.Context, url: String) {
    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(android.content.Intent.EXTRA_TEXT, url)
    }
    context.startActivity(android.content.Intent.createChooser(intent, "Share URL"))
}
