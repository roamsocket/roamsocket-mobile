package app.roamsocket.android.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Menu
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
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.roamsocket.android.ui.LocalAppContainer
import app.roamsocket.android.ui.LocalOpenSidebar
import app.roamsocket.android.ui.markdown.MarkdownText
import app.roamsocket.core.providers.ProviderId

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
    var showKeyDialog by remember { mutableStateOf(false) }
    var showModelPicker by remember { mutableStateOf(false) }

    // Auto-scroll the latest message into view.
    LaunchedEffect(state.messages.size, state.isStreaming) {
        if (state.messages.isNotEmpty()) {
            listState.animateScrollToItem(state.messages.size - 1)
        }
    }

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
                models = state.modelsForProvider,
                onSelectProvider = viewModel::selectProvider,
                onSelectModel = viewModel::selectModel,
                onDismiss = { showModelPicker = false },
            )
        }

        state.error?.let { err ->
            ErrorBanner(message = err, onDismiss = viewModel::dismissError)
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
                item("empty") { EmptyState(state.provider, state.hasApiKey) }
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
                MessageBubble(message = message, onRetry = onRetry)
            }
        }

        val hasUsableModel = state.model.isNotBlank() && when (state.provider) {
            is ProviderId.LocalMetal -> true
            else -> state.hasApiKey
        }
        ChatInputBar(
            draft = state.draft,
            isStreaming = state.isStreaming,
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
        )
    }
}

@Composable
private fun MessageBubble(message: ChatMessage, onRetry: (() -> Unit)? = null) {
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
                    // Port #8: assistant bubbles render their body as
                    // CommonMark / GFM via Markwon (mirrors iOS
                    // MarkdownContentView). The bubble loses the surface
                    // fill for assistant messages because the markdown
                    // renderer owns its own block / code-block backgrounds.
                    MarkdownText(
                        markdown = message.text,
                        fontSize = 16.sp,
                        modifier = Modifier.padding(horizontal = 4.dp),
                    )
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
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = onDraftChange,
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("Send a message…") },
                    enabled = !isStreaming,
                    singleLine = false,
                    maxLines = 4,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Sentences,
                        imeAction = ImeAction.Send,
                    ),
                )
                IconButton(
                    onClick = onSend,
                    enabled = !isStreaming && draft.isNotBlank(),
                ) {
                    Icon(Icons.AutoMirrored.Outlined.Send, contentDescription = "Send")
                }
            }
            // Port #9: model pill moved out of the top bar so the input bar
            // mirrors the iOS composer (text + send on top, model chip below).
            // The + button, camera, gallery and mic land in later PRs (#12, #7).
            ModelPickerPill(
                modelDisplayName = modelDisplayName,
                hasUsableModel = hasUsableModel,
                onPick = onPickModel,
                onAddModel = onAddModel,
                modifier = Modifier.padding(top = 6.dp),
            )
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

@Composable
private fun EmptyState(provider: ProviderId, hasApiKey: Boolean) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
    ) {
        if (!hasApiKey) {
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
        } else {
            Text(
                text = "Send a message to start chatting with ${provider.displayName}.",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
