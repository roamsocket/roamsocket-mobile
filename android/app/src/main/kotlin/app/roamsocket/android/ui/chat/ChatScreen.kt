package app.roamsocket.android.ui.chat

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.PickVisualMediaRequest
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.Menu
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.TheaterComedy
import androidx.compose.material.icons.outlined.LibraryBooks
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.roamsocket.android.ui.LocalAppContainer
import app.roamsocket.android.ui.LocalNavigateToCode
import app.roamsocket.android.ui.LocalNavigateToSettings
import app.roamsocket.android.ui.LocalNavigateToSidebar
import app.roamsocket.android.ui.LocalOpenSidebar
import app.roamsocket.android.ui.markdown.MarkdownContentView
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ProviderChatMessage
import app.roamsocket.core.providers.ProviderId
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Chat tab — the default landing screen. Mirrors the iOS `ChatView` in
 * spirit (scrollable transcript + input bar). Past PRs layered on
 * Markdown rendering (PR #49) and the failed-send retry chip
 * (PR #53); see the inline callouts.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    chatId: String? = null,
    viewModel: ChatViewModel = viewModel(
        key = "ChatScreen:${chatId ?: "blank"}",
        factory = ChatViewModel.factoryFor(LocalAppContainer.current, chatId),
    ),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()
    val context = LocalContext.current
    var showKeyDialog by remember { mutableStateOf(false) }
    var showModelPicker by remember { mutableStateOf(false) }
    // Port #12: Add to Chat sheet. The `+` button toggles this; the
    // sheet's callback chain also dismisses the sheet on selection.
    var showAddToChat by remember { mutableStateOf(false) }
    // PR #76: Incognito sheet. Toggled by the masks icon in the top bar.
    // When opened from a regular chat it starts a new incognito session;
    // when opened from an incognito chat it lets the user change the
    // lifetime or forget the chat immediately.
    var showIncognitoSheet by remember { mutableStateOf(false) }
    // PR #77: Voice chat overlay. Toggled by the mic icon in the input
    // bar. Renders as a full-screen Compose dialog over the chat so the
    // SpeechRecognizer / TTS lifecycle stays inside the chat process.
    var showVoiceChat by remember { mutableStateOf(false) }
    // PR #80: Message actions sheet. Toggled by long-pressing a
    // message bubble. Carries the message the user long-pressed so
    // the sheet can render the preview + call the right view-model
    // methods (Copy / Share / Delete).
    var actionsTarget by remember { mutableStateOf<ChatMessage?>(null) }
    // Pending camera output URI. We mint it on demand and feed it to
    // `TakePicture`; the camera writes the JPEG to this URI on success.
    var pendingCameraUri by remember { mutableStateOf<Uri?>(null) }

    // Port #7: image-attachment launchers. The gallery picker uses the
    // modern photo picker so no READ_MEDIA_IMAGES permission is needed
    // on Android 13+. The camera launcher needs a FileProvider URI we
    // pre-create (the OS grants the camera app write access to it).
    val galleryLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) viewModel.attachImage(uri, context.contentResolver)
    }
    val cameraLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.TakePicture(),
    ) { success ->
        val uri = pendingCameraUri
        if (success && uri != null) {
            viewModel.attachImage(uri, context.contentResolver)
        }
        pendingCameraUri = null
    }
    val onLaunchGallery: () -> Unit = {
        galleryLauncher.launch(
            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
        )
    }
    val onLaunchCamera: () -> Unit = {
        val uri = createCameraOutputUri(context)
        pendingCameraUri = uri
        cameraLauncher.launch(uri)
    }

    // Port #12: file-attachment launcher. Storage Access Framework via
    // OpenMultipleDocuments, so we get a per-URI grant the user can read
    // off the main thread (the model gets a `[Attached file: name]` block
    // inlined into the user message).
    val filePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        if (uris.isNotEmpty()) viewModel.addFiles(uris, context.contentResolver)
    }

    // Auto-scroll the latest message into view.
    LaunchedEffect(state.messages.size, state.isStreaming) {
        if (state.messages.isNotEmpty()) {
            listState.animateScrollToItem(state.messages.size - 1)
        }
    }

    // PR #76: when the chat screen is leaving composition (user
    // navigated to Code / sidebar / killed the activity), ask the
    // viewmodel to forget the active chat if it is an ON_EXIT
    // incognito. `DisposableEffect` on `Unit` fires `onDispose` once
    // on unmount, which is exactly the lifecycle event we want.
    androidx.compose.runtime.DisposableEffect(Unit) {
        onDispose {
            viewModel.forgetActiveIfOnExit()
        }
    }

    // Note: we used to auto-pop the API key dialog on first launch when the
    // active provider needed a key. That modal interrupted every cold start
    // (including the common "I just want to look at Recents" case) and pushed
    // users to add a key before they'd decided to chat. The dialog is still
    // reachable explicitly: the key icon in the top bar, the "Add API key"
    // CTA in the empty state, and Settings → Providers.

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
            title = {
                // Port #9: model picker moved out of the top bar and into
                // the input bar (see [ModelPickerPill] below). The title is
                // left intentionally generic; a future PR can replace this
                // with a derived chat title.
                Text(
                    text = "Chat",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            },
            actions = {
                // PR #76: incognito toggle. Tinted accent when the
                // active chat is already incognito so the user can see
                // they're in a private session at a glance.
                IconButton(onClick = { showIncognitoSheet = true }) {
                    Icon(
                        imageVector = Icons.Outlined.TheaterComedy,
                        contentDescription = if (state.isIncognito) {
                            "Incognito chat (active)"
                        } else {
                            "Start incognito chat"
                        },
                        tint = if (state.isIncognito) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurface
                        },
                    )
                }
                IconButton(onClick = { showKeyDialog = true }) {
                    Icon(Icons.Outlined.Key, contentDescription = "API key")
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = MaterialTheme.colorScheme.surface,
                titleContentColor = MaterialTheme.colorScheme.onSurface,
            ),
        )

        if (showKeyDialog) {
            ApiKeyDialog(
                provider = state.provider,
                onDismiss = { showKeyDialog = false },
                onSave = { key ->
                    viewModel.saveApiKey(key)
                    showKeyDialog = false
                },
            )
        }

        if (showModelPicker) {
            ModelPickerSheet(
                currentProvider = state.provider,
                currentModel = state.model,
                onSelectProvider = viewModel::selectProvider,
                onSelectModel = viewModel::selectModel,
                onAddModel = LocalNavigateToSettings.current,
                onDismiss = { showModelPicker = false },
            )
        }

        // Port #12: capture the navigation lambdas into local vars
        // because `compositionLocalOf.current` is a @Composable getter
        // and we need to invoke the result from inside non-composable
        // sheet callbacks below.
        val navigateToCode = LocalNavigateToCode.current
        val navigateToSidebar = LocalNavigateToSidebar.current

        if (showAddToChat) {
            AddToChatSheet(
                researchEnabled = state.researchEnabled,
                webSearchEnabled = state.webSearchEnabled,
                locationEnabled = state.locationEnabled,
                toolAccess = state.toolAccess,
                onDismiss = { showAddToChat = false },
                onStartCodingSession = navigateToCode,
                onAddFiles = {
                    // Use the SAF file picker with a permissive MIME
                    // filter so the user can attach anything from
                    // markdown notes to source code to PDFs. The
                    // attachment helper decides what to do with each
                    // type at read time.
                    filePickerLauncher.launch(arrayOf("*/*"))
                },
                onAddToProject = {
                    // "Projects" is a placeholder destination on the
                    // sidebar in this port; jumping to it is the
                    // cheapest thing that "works" without inventing a
                    // full project picker sheet.
                    navigateToSidebar(app.roamsocket.android.ui.sidebar.SidebarDestination.Projects)
                },
                onShowConnectors = {
                    // Connectors is also a sidebar placeholder for now.
                    navigateToSidebar(app.roamsocket.android.ui.sidebar.SidebarDestination.Browser)
                },
                onSetResearchEnabled = viewModel::setResearchEnabled,
                onSetWebSearchEnabled = viewModel::setWebSearchEnabled,
                onSetLocationEnabled = viewModel::setLocationEnabled,
                onSetToolAccess = viewModel::setToolAccess,
            )
        }

        // PR #76: incognito sheet. When the active chat is regular,
        // `onSelect` starts a new incognito chat with the chosen
        // lifetime. When the active chat is already incognito,
        // `onSelect` updates the existing lifetime in place and the
        // sheet's "Forget this chat now" button drops the chat and
        // reverts to a blank regular draft.
        if (showIncognitoSheet) {
            IncognitoChatSheet(
                activeLifetime = state.incognitoLifetime,
                onSelect = { lifetime ->
                    if (state.isIncognito) {
                        viewModel.setIncognitoLifetime(lifetime)
                    } else {
                        viewModel.startIncognitoChat(lifetime)
                    }
                },
                onForgetNow = { viewModel.forgetActiveIncognitoChat() },
                onDismiss = { showIncognitoSheet = false },
            )
        }

        state.error?.let { err ->
            ErrorBanner(message = err, onDismiss = viewModel::dismissError)
        }

        // Port #9: contextual hint above the input field — e.g. "your
        // current model doesn't support vision" when the user just
        // dropped a photo. Distinct from the top ErrorBanner, which
        // covers network / API failures.
        state.inlineError?.let { inline ->
            InlineErrorBanner(
                inline = inline,
                onDismiss = { viewModel.setInlineError(null) },
            )
        }

        LazyColumn(
            state = listState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            contentPadding = PaddingValues(vertical = 12.dp, horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (state.messages.isEmpty()) {
                item("empty") {
                    EmptyState(
                        provider = state.provider,
                        hasApiKey = state.hasApiKey,
                        liveModels = state.liveModelsForProvider,
                        onAddKey = { showKeyDialog = true },
                    )
                }
            }
            items(state.messages, key = { msg ->
                when (msg) {
                    is ChatMessage.User -> "u:" + msg.timestampMillis + ":" + msg.text.hashCode()
                    is ChatMessage.Assistant -> "a:" + msg.timestampMillis + ":" + msg.text.hashCode()
                }
            }) { message ->
                val onRetry: (() -> Unit)? = if (
                    message is ChatMessage.User &&
                    message.delivery == ChatMessage.User.Delivery.FAILED &&
                    !state.isStreaming
                ) {
                    { viewModel.retryLast() }
                } else null
                // Mirrors iOS `ChatMessageView.assistantMessageContent`:
                // the last assistant message is the one being streamed,
                // so the typing indicator only shows while that exact row
                // is empty.
                val isLastAssistant = message is ChatMessage.Assistant &&
                    state.messages.lastOrNull() === message
                MessageBubble(
                    message = message,
                    onRetry = onRetry,
                    alwaysExpandThinking = state.alwaysExpandThinking,
                    isStreaming = state.isStreaming && isLastAssistant,
                    isLatestAssistant = isLastAssistant,
                    // PR #79: pass the in-memory memory store so the
                    // bubble can surface a "Saved to memory" card
                    // under the assistant message that triggered the
                    // auto-save.
                    memoryStore = viewModel.memoryStore,
                    // PR #80: long-press to open the message actions
                    // sheet (Copy / Share / Delete). Mirrors the iOS
                    // inline action-button row that appears on hover.
                    onLongPress = { actionsTarget = message },
                )
            }
        }

        val hasUsableModel = state.model.isNotBlank() && when (state.provider) {
            is ProviderId.LocalMetal -> true
            else -> state.hasApiKey
        }
        ChatInputBar(
            draft = state.draft,
            isStreaming = state.isStreaming,
            attachedImages = state.attachedImages,
            attachedFiles = state.attachedFiles,
            onDraftChange = viewModel::updateDraft,
            onSend = { viewModel.send(state.draft) },
            modelDisplayName = state.modelsForProvider
                .firstOrNull { it.modelID == state.model }
                ?.displayName
                ?: state.model,
            hasUsableModel = hasUsableModel,
            onPickModel = { showModelPicker = true },
            onAddModel = {
                showKeyDialog = true
            },
            onAttachCamera = { onLaunchCamera() },
            onAttachGallery = { onLaunchGallery() },
            onOpenAddToChat = { showAddToChat = true },
            onMic = { showVoiceChat = true },
            onRemoveAttachment = { index -> viewModel.removeAttachedImage(index) },
            onRemoveFile = { index -> viewModel.removeAttachedFile(index) },
            // PR #78: study mode surfaces a locked "Sources" chip above
            // the input. Mirrors iOS `contextChips` / `studyMode` row.
            studyModeEnabled = state.studyModeEnabled,
        )
    }

    // PR #77: full-screen voice-chat overlay. Renders on top of the
    // chat composer so the SpeechRecognizer / TextToSpeech lifecycle
    // stays inside the chat process and the user can dismiss back
    // into the regular chat at any time.
    if (showVoiceChat) {
        VoiceChatScreen(
            onClose = { showVoiceChat = false },
            onSendTurn = { text ->
                // Stage the dictated text in the composer as a draft
                // and let the user confirm — matches the iOS flow
                // where the user can edit before the message is sent.
                // Auto-send mirrors iOS's "tap the mic to commit"
                // affordance when the user explicitly stops listening.
                viewModel.send(text)
            },
            onObserveReply = { callback ->
                // Capture the most recent assistant message. The chat
                // view-model streams updates into `messages`; the
                // voice layer just observes the trailing assistant
                // row. Wired here so the voice screen never needs to
                // reach into the chat view-model directly.
                callback(
                    state.messages.lastOrNull { it is ChatMessage.Assistant }
                        ?.let { (it as ChatMessage.Assistant).text }
                        .orEmpty(),
                )
            },
        )
    }

    // PR #80: message actions sheet (Copy / Share / Delete). Shown
    // when the user long-presses a message bubble. We render the
    // sheet on a single `actionsTarget` so the user can dismiss it
    // by tapping the scrim without losing the rest of the chat.
    actionsTarget?.let { target ->
        MessageActionsSheet(
            message = target,
            onCopy = { /* clipboard write is handled inside the sheet */ },
            onShare = { /* share intent is fired inside the sheet */ },
            onDelete = { viewModel.deleteMessage(target) },
            onDismiss = { actionsTarget = null },
        )
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun MessageBubble(
    message: ChatMessage,
    onRetry: (() -> Unit)? = null,
    alwaysExpandThinking: Boolean = false,
    isStreaming: Boolean = false,
    /** PR #79: when true, this assistant row is the latest in the transcript
     *  and gets to host the trailing memory hint card. */
    isLatestAssistant: Boolean = false,
    /** PR #79: shared memory store; when non-null and this is the
     *  latest assistant row, the trailing "Saved to memory" card renders
     *  under the bubble. */
    memoryStore: MemoryStore? = null,
    /** PR #80: long-press the bubble to open the message actions sheet. */
    onLongPress: (() -> Unit)? = null,
) {
    val isUser = message is ChatMessage.User
    val isFailed = isUser && (message as ChatMessage.User).delivery == ChatMessage.User.Delivery.FAILED
    val bubbleColor = when {
        isFailed -> MaterialTheme.colorScheme.error
        isUser -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.surfaceVariant
    }
    val textColor = if (isUser) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
    val shape = RoundedCornerShape(
        topStart = 16.dp,
        topEnd = 16.dp,
        bottomStart = if (isUser) 16.dp else 4.dp,
        bottomEnd = if (isUser) 4.dp else 16.dp,
    )
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = if (isUser) Alignment.End else Alignment.Start,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = { /* tap is a no-op; long-press is the affordance */ },
                    onLongClick = onLongPress,
                ),
            horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
        ) {
            when (message) {
                is ChatMessage.User -> Surface(
                    color = bubbleColor,
                    shape = shape,
                    modifier = Modifier.padding(horizontal = 4.dp),
                ) {
                    Text(
                        text = message.text,
                        color = textColor,
                        style = MaterialTheme.typography.bodyLarge,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                    )
                }
                is ChatMessage.Assistant -> {
                    // Parity with iOS `ChatMessageView.assistantMessageContent`:
                    // extract `<think>…</think>` blocks via the iOS-port
                    // [ThinkingExtractor] and render the reasoning as a
                    // collapsed row (clock + grey summary + tap-to-open
                    // Thought process sheet). The visible body goes through
                    // Markwon (Port #8) the same way it did before.
                    val parsed = ThinkingExtractor.extract(message.text)
                    val cleaned = ThinkingExtractor
                        .stripControlTokens(parsed.content)
                        .let { ThinkingExtractor.stripToolCallXml(it) }
                    Column(modifier = Modifier.padding(horizontal = 4.dp)) {
                        parsed.thinking?.let { thinking ->
                            ThinkingBlock(
                                text = thinking,
                                expanded = alwaysExpandThinking,
                            )
                            Spacer(Modifier.size(8.dp))
                        }
                        if (cleaned.isNotBlank()) {
                            MarkdownContentView(
                                text = cleaned,
                                fontSize = 16.sp,
                            )
                        }
                        // While the assistant is mid-turn and there's no
                        // visible progress yet, surface a typing indicator
                        // so the user knows the agent is still working
                        // (mirrors iOS `shouldShowTypingIndicator`).
                        if (isStreaming && parsed.thinking == null && cleaned.isBlank()) {
                            Spacer(Modifier.size(4.dp))
                            AssistantTypingIndicator()
                        }
                        // PR #79: surface the most recent memory
                        // activity row as a "Saved to memory" card
                        // under the trailing assistant message. The
                        // activity log is global; we pair it with the
                        // latest assistant row so a long transcript
                        // doesn't end up with every old card stacked
                        // on the final bubble.
                        if (memoryStore != null && isLatestAssistant) {
                            val latest = memoryStore.activity.collectAsState().value
                                .lastOrNull()
                            if (latest != null) {
                                Spacer(Modifier.size(8.dp))
                                MemoryHintCard(
                                    memory = memoryStore,
                                    activityID = latest.id,
                                )
                            }
                        }
                    }
                }
            }
        }
        if (isFailed) {
            val reason = (message as ChatMessage.User).failureReason
            Row(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = reason?.let { "Couldn't send: $it" } ?: "Couldn't send this message.",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (onRetry != null) {
                    TextButton(
                        onClick = onRetry,
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 10.dp, vertical = 0.dp),
                    ) { Text("Retry") }
                }
            }
        }
    }
}

@Composable
private fun ChatInputBar(
    draft: String,
    isStreaming: Boolean,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    modelDisplayName: String,
    hasUsableModel: Boolean,
    onPickModel: () -> Unit,
    onAddModel: () -> Unit,
    onAttachCamera: () -> Unit,
    onAttachGallery: () -> Unit,
    onOpenAddToChat: () -> Unit,
    onMic: () -> Unit,
    onRemoveAttachment: (Int) -> Unit,
    onRemoveFile: (Int) -> Unit,
    attachedImages: List<ProviderChatMessage.ImageAttachment>,
    attachedFiles: List<ProviderChatMessage.FileAttachment>,
    /** PR #78: when true, the composer shows a locked "Sources" chip. */
    studyModeEnabled: Boolean = false,
) {
    Surface(
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 2.dp,
        modifier = Modifier.imePadding(),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            // PR #78: locked "Sources" chip when Study mode is on.
            // Mirrors iOS `contextChips` / `studyMode` row above the
            // composer. The chip is non-tappable (the flag is
            // toggled from the sidebar graduation-cap) and just
            // signals to the user that the reply will cite.
            if (studyModeEnabled) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.padding(bottom = 6.dp),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.LibraryBooks,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(14.dp),
                    )
                    Text(
                        text = "Sources on",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "Study mode forces citations on every reply.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            // Port #7: image attachments. Render a horizontal row of
            // removable chips above the text field when the user has
            // picked images but not sent them yet. Clearing all
            // attachments collapses the row.
            if (attachedImages.isNotEmpty()) {
                AttachedImagesRow(
                    images = attachedImages,
                    onRemove = onRemoveAttachment,
                    modifier = Modifier.padding(bottom = 6.dp),
                )
            }
            // Port #12: file attachments (Add to Chat → Add files). The
            // chip row sits between the image row and the text field so
            // the user can see what they've queued regardless of order.
            if (attachedFiles.isNotEmpty()) {
                AttachedFilesRow(
                    files = attachedFiles,
                    onRemove = onRemoveFile,
                    modifier = Modifier.padding(bottom = 6.dp),
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = onDraftChange,
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("Message RoamSocket") },
                    enabled = !isStreaming,
                    singleLine = false,
                    maxLines = 4,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Sentences,
                        imeAction = ImeAction.Send,
                    ),
                )
            }
            // Bottom row: left = "+" + model pill, right = camera + gallery + mic/send
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Left side: + button + model picker pill
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    IconButton(
                        onClick = onOpenAddToChat,
                        enabled = !isStreaming,
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Add,
                            contentDescription = "Add to Chat",
                            tint = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                    ModelPickerPill(
                        modelDisplayName = modelDisplayName,
                        hasUsableModel = hasUsableModel,
                        onPick = onPickModel,
                        onAddModel = LocalNavigateToSettings.current,
                    )
                }

                Spacer(modifier = Modifier.weight(1f))

                // Right side: camera + gallery + mic/send
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    IconButton(
                        onClick = onAttachCamera,
                        enabled = !isStreaming,
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.PhotoCamera,
                            contentDescription = "Attach from camera",
                            tint = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                    IconButton(
                        onClick = onAttachGallery,
                        enabled = !isStreaming,
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Image,
                            contentDescription = "Attach from gallery",
                            tint = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                    if (draft.isNotBlank() || attachedImages.isNotEmpty() || attachedFiles.isNotEmpty()) {
                        IconButton(
                            onClick = onSend,
                            enabled = !isStreaming,
                        ) {
                            Icon(Icons.AutoMirrored.Outlined.Send, contentDescription = "Send")
                        }
                    } else {
                        IconButton(
                            onClick = onMic,
                            enabled = !isStreaming,
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.Mic,
                                contentDescription = "Voice chat",
                                tint = MaterialTheme.colorScheme.onSurface,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AttachedImagesRow(
    images: List<ProviderChatMessage.ImageAttachment>,
    onRemove: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Inline base64 previews need an image decoder, so for the first
    // port we just show a removable chip per attachment. A real
    // thumbnail grid (with the Coil / Glide picker) is a follow-up.
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        images.forEachIndexed { index, _ ->
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                shape = RoundedCornerShape(50),
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .clickable { onRemove(index) },
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Image,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(
                        text = "Image ${index + 1}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Icon(
                        imageVector = Icons.Outlined.Close,
                        contentDescription = "Remove image ${index + 1}",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
        }
    }
}

/**
 * Chip row for the files the user picked via the Add to Chat sheet
 * (port #12 → "Add files"). Mirrors [AttachedImagesRow] but uses a
 * document icon and the file's display name. Tap-to-remove a chip.
 */
@Composable
private fun AttachedFilesRow(
    files: List<ProviderChatMessage.FileAttachment>,
    onRemove: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        files.forEachIndexed { index, file ->
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                shape = RoundedCornerShape(50),
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .clickable { onRemove(index) },
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Add,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(
                        text = file.displayName,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                    )
                    Icon(
                        imageVector = Icons.Outlined.Close,
                        contentDescription = "Remove ${file.displayName}",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun InlineErrorBanner(
    inline: InlineError,
    onDismiss: () -> Unit,
) {
    // Subtle dark-fill banner; the message is the primary content and
    // the action pill (if any) lives on the right. Pairs visually with
    // the model-pill capsule below it.
    Surface(
        color = MaterialTheme.colorScheme.errorContainer,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.ErrorOutline,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onErrorContainer,
                modifier = Modifier.size(18.dp),
            )
            Text(
                text = inline.message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onErrorContainer,
                modifier = Modifier.weight(1f),
            )
            if (inline.actionLabel != null && inline.onAction != null) {
                TextButton(
                    onClick = {
                        inline.onAction.invoke()
                        onDismiss()
                    },
                ) {
                    Text(inline.actionLabel)
                }
            }
            IconButton(
                onClick = onDismiss,
                modifier = Modifier.size(28.dp),
            ) {
                Icon(
                    imageVector = Icons.Outlined.Close,
                    contentDescription = "Dismiss",
                    tint = MaterialTheme.colorScheme.onErrorContainer,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

@Composable
private fun ErrorBanner(message: String, onDismiss: () -> Unit) {
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
            Text(
                text = "Dismiss",
                color = MaterialTheme.colorScheme.onError,
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier
                    .clip(RoundedCornerShape(4.dp))
                    .background(Color.Transparent)
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
            IconButton(onClick = onDismiss) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Dismiss", tint = MaterialTheme.colorScheme.onError)
            }
        }
    }
}

/**
 * Empty-state copy shown above the input bar when the chat has no
 * messages yet. Mirrors the iOS empty state (lightbulb + "What are we
 * building today?") so the two apps feel consistent on first launch.
 */
@Composable
private fun EmptyState(
    provider: ProviderId,
    hasApiKey: Boolean,
    liveModels: List<AIModel>?,
    onAddKey: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 32.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        when {
            // No key at all — full call-to-action (PR #57). The user has
            // not added a provider key yet, so the empty state nudges
            // them toward Settings (Providers is the first row) rather
            // than the default "what are we building" hero.
            !hasApiKey -> {
                Text(
                    text = "Add an API key for ${provider.displayName}",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = "Tap the key icon in the top bar (or open Settings) to paste your ${provider.displayName} key. Messages you send before adding a key are saved here so you can resume once you're set up.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            // Key is set but the upstream returned no models. Most likely a 401
            // (wrong/expired key) — surface a way to fix it without burying it
            // in a Dismiss-only error banner.
            liveModels != null && liveModels.isEmpty() -> {
                Text(
                    text = "Couldn't load models for ${provider.displayName}",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = "Your API key may be invalid or expired. Tap below to update it; we'll re-fetch the model list automatically.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                TextButton(onClick = onAddKey) { Text("Update API key") }
            }
            // Still loading live models — quiet placeholder so the screen
            // doesn't blink an empty state for half a second.
            liveModels == null -> {
                Text(
                    text = "Loading ${provider.displayName} models…",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            // Happy-path empty state. Lightbulb in a circular surface
            // (matches the iOS reference screenshot 1) plus the
            // time-of-day greeting (port of iOS `ChatGreeting.phrase(at:)`)
            // rendered in a serif font for the iOS "literary" feel. The
            // line rotates by hour + day so it doesn't always say the
            // same thing.
            else -> {
                Box(
                    modifier = Modifier
                        .size(56.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Filled.Lightbulb,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(36.dp),
                    )
                }
                Spacer(Modifier.size(18.dp))
                Text(
                    text = ChatGreeting.phrase(),
                    style = MaterialTheme.typography.headlineSmall.copy(
                        fontFamily = FontFamily.Serif,
                        fontWeight = FontWeight.Normal,
                    ),
                    color = MaterialTheme.colorScheme.onSurface,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
    }
}

/**
 * Mint a fresh content:// URI under the app's FileProvider for the
 * camera to write into. We stash the file in the cache dir (which the
 * system can reclaim), and the path is named after the timestamp so
 * successive captures don't clobber each other.
 */
private fun createCameraOutputUri(context: Context): Uri {
    val dir = File(context.cacheDir, "camera").apply { mkdirs() }
    val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
    val file = File(dir, "capture_$timestamp.jpg")
    return FileProvider.getUriForFile(
        context,
        "${context.packageName}.fileprovider",
        file,
    )
}
