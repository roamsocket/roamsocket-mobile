package app.roamsocket.android.ui.chat

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.PickVisualMediaRequest
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import app.roamsocket.android.ui.markdown.MarkdownText
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
            onMic = { /* TODO: voice chat */ },
            onRemoveAttachment = { index -> viewModel.removeAttachedImage(index) },
            onRemoveFile = { index -> viewModel.removeAttachedFile(index) },
        )
    }
}

@Composable
private fun MessageBubble(
    message: ChatMessage,
    onRetry: (() -> Unit)? = null,
    alwaysExpandThinking: Boolean = false,
    isStreaming: Boolean = false,
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
            modifier = Modifier.fillMaxWidth(),
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
                            MarkdownText(
                                markdown = cleaned,
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
