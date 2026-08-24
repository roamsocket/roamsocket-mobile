package app.roamsocket.android.ui.browser

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.roamsocket.android.AppContainer
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ModelProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Owns every tab, the address/AI prompt state, bookmarks, history, and
 * the plan/approve execution loop for the in-app browser. Mirrors the
 * iOS `BrowserStore` so the wire format + UI state shape are 1:1.
 *
 * Lives on the [AppContainer] (like `codeSessionRepository`) so tabs and
 * history survive leaving/returning to the Browser sidebar destination.
 */
class BrowserStore(
    private val container: AppContainer,
    val preferences: BrowserPreferences,
    private val appScope: CoroutineScope,
) : ViewModel() {

    // MARK: - Tab state

    private val _tabs = MutableStateFlow<List<BrowserTabState>>(emptyList())
    val tabs: StateFlow<List<BrowserTabState>> = _tabs.asStateFlow()

    private val _activeTabId = MutableStateFlow<String?>(null)
    val activeTabId: StateFlow<String?> = _activeTabId.asStateFlow()

    val activeTab: BrowserTabState?
        get() = _tabs.value.firstOrNull { it.id == _activeTabId.value }

    // MARK: - Address / prompt state

    private val _addressText = MutableStateFlow("")
    val addressText: StateFlow<String> = _addressText.asStateFlow()

    private val _promptText = MutableStateFlow("")
    val promptText: StateFlow<String> = _promptText.asStateFlow()

    private val _promptMode = MutableStateFlow(BrowserPromptMode.ACT)
    val promptMode: StateFlow<BrowserPromptMode> = _promptMode.asStateFlow()

    // MARK: - Plan / ask state

    private val _isPlanning = MutableStateFlow(false)
    val isPlanning: StateFlow<Boolean> = _isPlanning.asStateFlow()

    private val _isAsking = MutableStateFlow(false)
    val isAsking: StateFlow<Boolean> = _isAsking.asStateFlow()

    private val _chatMessages = MutableStateFlow<List<BrowserChatMessage>>(emptyList())
    val chatMessages: StateFlow<List<BrowserChatMessage>> = _chatMessages.asStateFlow()

    private val _isPlanRunning = MutableStateFlow(false)
    val isPlanRunning: StateFlow<Boolean> = _isPlanRunning.asStateFlow()

    private val _isDecidingNextStep = MutableStateFlow(false)
    val isDecidingNextStep: StateFlow<Boolean> = _isDecidingNextStep.asStateFlow()

    private val _pendingPlan = MutableStateFlow<BrowserPlan?>(null)
    val pendingPlan: StateFlow<BrowserPlan?> = _pendingPlan.asStateFlow()

    private val _runningPlan = MutableStateFlow<BrowserPlan?>(null)
    val runningPlan: StateFlow<BrowserPlan?> = _runningPlan.asStateFlow()

    private val _pendingStepsApproval = MutableStateFlow<List<BrowserStep>?>(null)
    val pendingStepsApproval: StateFlow<List<BrowserStep>?> = _pendingStepsApproval.asStateFlow()

    private val _currentCommentary = MutableStateFlow<String?>(null)
    val currentCommentary: StateFlow<String?> = _currentCommentary.asStateFlow()

    private val _completionSummary = MutableStateFlow<String?>(null)
    val completionSummary: StateFlow<String?> = _completionSummary.asStateFlow()

    private val _completionOutcome = MutableStateFlow(CompletionOutcome.SUCCESS)
    val completionOutcome: StateFlow<CompletionOutcome> = _completionOutcome.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    // MARK: - UI sheet state

    private val _showTabsSheet = MutableStateFlow(false)
    val showTabsSheet: StateFlow<Boolean> = _showTabsSheet.asStateFlow()

    private val _showBookmarksSheet = MutableStateFlow(false)
    val showBookmarksSheet: StateFlow<Boolean> = _showBookmarksSheet.asStateFlow()

    private val _showModelPicker = MutableStateFlow(false)
    val showModelPicker: StateFlow<Boolean> = _showModelPicker.asStateFlow()

    /** The model the browser's AI prompt bar is using. */
    val selectedModel: StateFlow<AIModel?>
        get() = _selectedModel
    private val _selectedModel = MutableStateFlow<AIModel?>(null)

    /** True when the current model picker can't drive the agent (no model, no key). */
    val needsModel: Boolean
        get() = _selectedModel.value == null

    // MARK: - Cancellation handles

    /** Handle to the in-flight initial plan generation (between send and the approval card). */
    private var planningJob: Job? = null

    /** Handle to the in-flight Ask-mode chat call. */
    private var askJob: Job? = null

    /** Handle to the in-flight plan execution loop. */
    private var runningPlanJob: Job? = null

    /** Set when the user explicitly stopped the run. */
    private var wasStoppedByUser: Boolean = false

    /** Snapshot of the prompt text the user just submitted. */
    var pendingPromptText: String? = null

    /** Hard cap so a confused loop can't run forever. */
    private val maxStepsPerRun: Int = 12

    init {
        // Default to the user's last-selected chat model so the browser
        // doesn't open with a confusing "no model" pill on first run.
        viewModelScope.launch {
            val provider = container.userSettings.currentProvider.first()
            val modelId = container.userSettings.currentModel.first()
            if (modelId.isNotEmpty()) {
                _selectedModel.value = AIModel(
                    provider = provider,
                    modelID = modelId,
                    displayName = AIModel.prettifiedDisplayName(modelId, provider),
                )
            }
        }
        // Make sure there's at least one tab on first open.
        if (_tabs.value.isEmpty()) {
            newTab()
        }
    }

    // MARK: - Tabs

    fun newTab(url: String? = null) {
        val tab = BrowserTabState()
        _tabs.value = _tabs.value + tab
        _activeTabId.value = tab.id
        _addressText.value = ""
        if (url != null) tab.loadUrl(url)
    }

    fun closeTab(id: String) {
        _tabs.value = _tabs.value.filter { it.id != id }
        if (_activeTabId.value == id) {
            val next = _tabs.value.lastOrNull()
            _activeTabId.value = next?.id
            _addressText.value = next?.urlString?.value.orEmpty()
        }
        if (_tabs.value.isEmpty()) newTab()
    }

    fun selectTab(id: String) {
        _activeTabId.value = id
        _addressText.value = _tabs.value.firstOrNull { it.id == id }?.urlString?.value.orEmpty()
        _showTabsSheet.value = false
    }

    /**
     * Re-snapshot every tab for the tab-switcher preview grid. Best-effort:
     * some pages can't be captured (canvas-heavy, cross-origin iframes),
     * in which case the tab keeps its previous snapshot or stays `null`.
     */
    fun refreshAllSnapshots() {
        for (tab in _tabs.value) {
            tab.snapshotForTabSwitcher()
        }
    }

    // MARK: - Address bar

    fun updateAddressText(text: String) {
        _addressText.value = text
    }

    fun updatePromptText(text: String) {
        _promptText.value = text
    }

    fun setPromptMode(mode: BrowserPromptMode) {
        _promptMode.value = mode
    }

    fun setShowTabsSheet(value: Boolean) { _showTabsSheet.value = value }
    fun setShowBookmarksSheet(value: Boolean) { _showBookmarksSheet.value = value }
    fun setShowModelPicker(value: Boolean) { _showModelPicker.value = value }
    fun setSelectedModel(model: AIModel?) {
        _selectedModel.value = model
        if (model != null) {
            // Mirror the chat's "selected model" so other screens stay in sync.
            viewModelScope.launch {
                container.userSettings.setCurrent(model.provider, model.modelID)
            }
        }
    }

    fun goToAddress() {
        val url = BrowserAddressResolver.resolve(_addressText.value)
        if (url == null) {
            _errorMessage.value = "Enter a valid address or search."
            return
        }
        if (activeTab == null) newTab()
        activeTab?.loadUrl(url)
    }

    fun onPageFinished(tab: BrowserTabState) {
        if (tab.id == _activeTabId.value) _addressText.value = tab.urlString.value
        val url = tab.urlString.value
        if (url.isNotEmpty() && url.startsWith("http")) {
            preferences.addHistory(
                BrowserHistoryEntry(
                    title = if (tab.title.value.isEmpty()) url else tab.title.value,
                    url = url,
                ),
            )
        }
    }

    // MARK: - Bookmarks

    val bookmarks: StateFlow<List<BrowserBookmark>> get() = preferences.bookmarks

    fun addBookmarkForCurrentPage() {
        val tab = activeTab ?: return
        val url = tab.urlString.value
        if (url.isEmpty()) return
        if (bookmarks.value.any { it.url == url }) return
        preferences.addBookmark(BrowserBookmark(title = tab.title.value, url = url))
    }

    fun removeBookmark(id: String) {
        preferences.removeBookmark(id)
    }

    fun openBookmark(bookmark: BrowserBookmark) {
        if (activeTab == null) newTab()
        activeTab?.loadUrl(bookmark.url)
        _showBookmarksSheet.value = false
    }

    val isCurrentPageBookmarked: Boolean
        get() {
            val tab = activeTab ?: return false
            return bookmarks.value.any { it.url == tab.urlString.value }
        }

    // MARK: - History

    val history: StateFlow<List<BrowserHistoryEntry>> get() = preferences.history

    fun clearHistory() {
        preferences.clearHistory()
    }

    fun openFromHistory(entry: BrowserHistoryEntry) {
        if (activeTab == null) newTab()
        activeTab?.loadUrl(entry.url)
        _showBookmarksSheet.value = false
    }

    // MARK: - AI agent entry points

    fun denyPendingPlan() {
        _pendingPlan.value = null
        clearPendingPrompt()
    }

    fun clearChat() {
        _chatMessages.value = emptyList()
    }

    fun dismissError() {
        _errorMessage.value = null
    }

    fun dismissRunningPlan() {
        _runningPlan.value = null
        _currentCommentary.value = null
        _completionSummary.value = null
    }

    fun approvePlanBulk() {
        val plan = _pendingPlan.value ?: return
        preferences.setGranularity(BrowserApprovalGranularity.BULK)
        beginRun(plan, bulk = true)
    }

    fun approvePlanStepByStep() {
        val plan = _pendingPlan.value ?: return
        preferences.setGranularity(BrowserApprovalGranularity.STEP_BY_STEP)
        beginRun(plan, bulk = false)
    }

    fun respondToPendingStep(allow: Boolean) {
        val steps = _pendingStepsApproval.value ?: return
        _pendingStepsApproval.value = null
        if (!allow) {
            // Single-step deny → end the run with a "stopped" banner so the
            // user can see their decision without leaving a stale plan.
            wasStoppedByUser = true
            finishRun(CompletionOutcome.STOPPED, summary = "Step denied.")
            return
        }
        // Resume the run loop with the next batch.
        runningPlanJob = viewModelScope.launch {
            executeSteps(steps)
        }
    }

    /**
     * Stop the in-flight agent: planning shimmer, ask chat, or executing
     * a plan. Safe to call any time (no-op when nothing is running).
     */
    fun stopRun() {
        wasStoppedByUser = true
        planningJob?.cancel()
        askJob?.cancel()
        runningPlanJob?.cancel()
        _isPlanning.value = false
        _isAsking.value = false
        if (_isPlanRunning.value || _runningPlan.value != null) {
            finishRun(CompletionOutcome.STOPPED, summary = "Stopped by you.")
        } else {
            clearPendingPrompt()
        }
    }

    fun submitPrompt() {
        val goal = _promptText.value.trim()
        if (goal.isEmpty()) return
        if (_isAsking.value || _isPlanning.value) return
        val model = _selectedModel.value
        if (model == null) {
            _errorMessage.value = "Pick a model first (Settings → API keys, or use the model picker in Chat)."
            return
        }
        // Check the API key is present for the selected provider.
        viewModelScope.launch {
            val apiKey = container.secretStore.readApiKey(model.provider).orEmpty()
            if (apiKey.isEmpty() && model.provider.requiresApiKey) {
                _errorMessage.value = "Add an API key for ${model.provider.displayName} first."
                return@launch
            }
            val provider = container.chatClientFor(model.provider)
            if (provider == null) {
                _errorMessage.value = "Provider ${model.provider.displayName} has no Android client yet."
                return@launch
            }
            pendingPromptText = goal
            _errorMessage.value = null
            if (_promptMode.value == BrowserPromptMode.ASK) {
                startAsk(goal, model, apiKey, provider)
            } else {
                startPlanning(goal, model, apiKey, provider)
            }
        }
    }

    private fun startAsk(goal: String, model: AIModel, apiKey: String, provider: ModelProvider) {
        _isAsking.value = true
        // Append the user message optimistically.
        _chatMessages.value = _chatMessages.value + BrowserChatMessage(
            role = BrowserChatMessage.Role.USER, content = goal,
        )
        askJob = viewModelScope.launch {
            try {
                val tab = activeTab
                val context = if (tab != null) {
                    // Wait for the page to settle, then snapshot.
                    BrowserTabActions.waitForSettle(tab)
                    BrowserTabActions.captureContext(tab)
                } else {
                    BrowserPageContext("", "", "", emptyList())
                }
                val history = _chatMessages.value.dropLast(1) // exclude the just-appended user msg
                val reply = BrowserAgent.askAboutPage(
                    question = goal, context = context, history = history,
                    model = model, apiKey = apiKey, provider = provider,
                )
                _chatMessages.value = _chatMessages.value + BrowserChatMessage(
                    role = BrowserChatMessage.Role.ASSISTANT, content = reply,
                )
            } catch (e: Throwable) {
                _errorMessage.value = e.message ?: "Ask failed."
            } finally {
                _isAsking.value = false
                clearPendingPrompt()
            }
        }
    }

    private fun startPlanning(goal: String, model: AIModel, apiKey: String, provider: ModelProvider) {
        _completionSummary.value = null
        _completionOutcome.value = CompletionOutcome.SUCCESS
        _isPlanning.value = true
        planningJob = viewModelScope.launch {
            try {
                val tab = activeTab
                val (context, imageBytes) = if (tab != null) {
                    BrowserTabActions.waitForSettle(tab)
                    val ctx = BrowserTabActions.captureContext(tab)
                    val needsImage = ctx.textSnippet.length < BrowserAgent.IMAGE_FALLBACK_TEXT_THRESHOLD
                        || BrowserAgent.looksLikeConsentPage(ctx.textSnippet)
                    val bytes = if (needsImage) captureTabImage(tab) else null
                    ctx to bytes
                } else {
                    BrowserPageContext("", "", "", emptyList()) to null
                }
                val plan = BrowserAgent.requestPlan(
                    goal = goal, context = context,
                    attachedImageBytes = imageBytes,
                    attachedImageMime = "image/jpeg",
                    model = model, apiKey = apiKey, provider = provider,
                )
                _pendingPlan.value = plan
            } catch (e: Throwable) {
                if (e is kotlinx.coroutines.CancellationException) return@launch
                _errorMessage.value = e.message ?: "Failed to plan."
                clearPendingPrompt()
            } finally {
                _isPlanning.value = false
            }
        }
    }

    private suspend fun captureTabImage(tab: BrowserTabState): ByteArray? {
        // Render the WebView to a bitmap via Picture.capture, then JPEG-encode.
        val bitmap = tab.snapshot.value ?: run {
            tab.snapshotForTabSwitcher()
            tab.snapshot.value
        } ?: return null
        val out = java.io.ByteArrayOutputStream()
        bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 70, out)
        return out.toByteArray()
    }

    private fun beginRun(plan: BrowserPlan, bulk: Boolean) {
        // Cancel any prior run before starting a new one.
        runningPlanJob?.cancel()
        wasStoppedByUser = false
        _pendingPlan.value = null
        _completionSummary.value = null
        _completionOutcome.value = CompletionOutcome.SUCCESS
        _isPlanRunning.value = true
        _runningPlan.value = BrowserPlan(id = plan.id, goal = plan.goal, steps = emptyList())
        runningPlanJob = viewModelScope.launch {
            executeSteps(plan.steps)
        }
    }

    /**
     * The plan execution loop. Runs the supplied [initialQueue] once, then
     * after each step re-analyzes the live page to decide what to do next.
     * In BULK mode the re-decision is auto-approved; in STEP_BY_STEP mode
     * the decision pauses for the user.
     */
    private suspend fun executeSteps(initialQueue: List<BrowserStep>) {
        val queue = initialQueue.toMutableList()
        var ran = 0
        try {
            while (queue.isNotEmpty() && ran < maxStepsPerRun) {
                val step = queue.removeAt(0)
                val tab = activeTab
                if (tab == null) {
                    finishRun(CompletionOutcome.BLOCKED, summary = "No active tab.")
                    return
                }
                // Mark running in the live list.
                _runningPlan.value = _runningPlan.value?.let { it.copy(steps = it.steps + step.copy(status = BrowserStep.Status.RUNNING)) }
                val ok = executeStep(tab, step)
                val finalStep = step.copy(
                    status = if (ok) BrowserStep.Status.DONE else BrowserStep.Status.FAILED,
                )
                _runningPlan.value = _runningPlan.value?.let { current ->
                    val updated = current.steps.dropLast(1) + finalStep
                    current.copy(steps = updated)
                }
                if (!ok) {
                    finishRun(CompletionOutcome.BLOCKED, summary = "Step failed: ${step.description}")
                    return
                }
                ran++
                // Settle then decide what to do next.
                BrowserTabActions.waitForSettle(tab)
                if (queue.isEmpty()) {
                    // Ask the model what's next.
                    _isDecidingNextStep.value = true
                    val model = _selectedModel.value ?: run {
                        finishRun(CompletionOutcome.SUCCESS)
                        return
                    }
                    val apiKey = container.secretStore.readApiKey(model.provider).orEmpty()
                    val ctx = BrowserTabActions.captureContext(tab)
                    val nextProvider = container.chatClientFor(model.provider)
                    val nextPlan = if (nextProvider == null) null else try {
                        BrowserAgent.requestPlan(
                            goal = "Continue: ${_runningPlan.value?.goal.orEmpty()}",
                            context = ctx, attachedImageBytes = null, attachedImageMime = "image/jpeg",
                            model = model, apiKey = apiKey, provider = nextProvider,
                        )
                    } catch (_: Throwable) { null }
                    _isDecidingNextStep.value = false
                    if (nextPlan == null || nextPlan.steps.isEmpty()) {
                        finishRun(CompletionOutcome.SUCCESS)
                        return
                    }
                    val granularity = preferences.granularity.value
                    if (granularity == BrowserApprovalGranularity.STEP_BY_STEP) {
                        _pendingStepsApproval.value = nextPlan.steps
                        return
                    } else {
                        queue.addAll(nextPlan.steps)
                    }
                }
            }
            if (ran >= maxStepsPerRun) {
                finishRun(CompletionOutcome.STOPPED, summary = "Hit the safety limit of $maxStepsPerRun steps.")
            } else if (!wasStoppedByUser) {
                finishRun(CompletionOutcome.SUCCESS)
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            // User stopped. Banner already set by `stopRun`.
            throw e
        } catch (e: Throwable) {
            finishRun(CompletionOutcome.BLOCKED, summary = e.message ?: "Plan failed.")
        }
    }

    private suspend fun executeStep(tab: BrowserTabState, step: BrowserStep): Boolean {
        return when (step.kind) {
            BrowserStep.Kind.NAVIGATE -> {
                val target = step.target ?: return false
                tab.loadUrl(target)
                true
            }
            BrowserStep.Kind.CLICK -> {
                val target = step.target ?: return false
                BrowserTabActions.click(tab, target)
            }
            BrowserStep.Kind.TYPE -> {
                val target = step.target ?: return false
                val value = step.value ?: return false
                BrowserTabActions.type(tab, target, value, submit = false)
            }
            BrowserStep.Kind.SCROLL -> {
                val target = step.target ?: "down"
                BrowserTabActions.scroll(tab, target)
                true
            }
            BrowserStep.Kind.BACK -> {
                if (tab.canGoBack.value) tab.goBack()
                true
            }
            BrowserStep.Kind.FORWARD -> {
                if (tab.canGoForward.value) tab.goForward()
                true
            }
            BrowserStep.Kind.RELOAD -> {
                tab.reload()
                true
            }
            BrowserStep.Kind.WAIT -> {
                val seconds = step.target?.toIntOrNull() ?: 1
                delay(seconds * 1000L)
                true
            }
            BrowserStep.Kind.EXTRACT -> {
                // The "extract" step is a no-op at execution time — the
                // next re-plan call already reads the page text and will
                // fold the summary into the next plan.
                true
            }
            BrowserStep.Kind.DISMISS_CONSENT -> {
                BrowserTabActions.dismissConsent(tab).ok
            }
        }
    }

    private fun finishRun(outcome: CompletionOutcome, summary: String? = null) {
        _isPlanRunning.value = false
        _completionOutcome.value = outcome
        _completionSummary.value = summary
        clearPendingPrompt()
    }

    private fun clearPendingPrompt() {
        pendingPromptText = null
        _promptText.value = ""
    }

    /** The reason the run ended — drives the finished banner's icon and tint. */
    enum class CompletionOutcome { SUCCESS, BLOCKED, STOPPED }

    /**
     * Re-export of preferences' granularity so the UI doesn't have to
     * thread two state sources.
     */
    val granularity: StateFlow<BrowserApprovalGranularity> get() = preferences.granularity
}
