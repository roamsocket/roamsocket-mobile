package app.roamsocket.android.ui.chat

import android.app.Application
import android.content.ContentResolver
import android.net.Uri
import android.util.Base64
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
import app.roamsocket.core.chats.ChatHistoryRepository
import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ModelCatalog
import app.roamsocket.core.providers.ProviderChatMessage
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Drives the Chat tab. Loads the persisted provider + model, looks up the
 * matching API key, and exposes a state stream the Compose screen renders.
 *
 * Persistence (PR 1): each chat has a stable [chatId] (UUID). On open, the
 * view-model hydrates `messages` from the [ChatHistoryRepository]. On every
 * send, it persists the new transcript so the sidebar's Recents list and
 * the next launch can resume the conversation.
 */
class ChatViewModel(
    private val container: AppContainer,
    /** Stable id of the chat being viewed. `null` = fresh blank chat. */
    private val chatId: String? = null,
) : ViewModel() {

    private val _state = MutableStateFlow(ChatUiState())
    val state: StateFlow<ChatUiState> = _state.asStateFlow()

    /**
     * Effective chat id. The view-model lazily creates a blank draft on
     * the first send so the user can compose before deciding to commit.
     */
    private var effectiveChatId: String? = chatId

    init {
        viewModelScope.launch {
            val provider = container.userSettings.currentProvider.first()
            val model = container.userSettings.currentModel.first()
            applySelection(provider, model)

            // Surface whether the current provider has an API key so the
            // empty state can prompt the user to add one (rather than let
            // them type a message and watch it silently fail).
            val apiKey = container.secretStore.readApiKey(provider)
            _state.value = _state.value.copy(hasApiKey = !apiKey.isNullOrEmpty())

            // Resume the persisted transcript when the screen opens on an
            // existing chat id.
            val id = effectiveChatId
            if (id != null) {
                val repoItem = container.chatHistoryRepository.snapshot()
                    .firstOrNull { it.id == id }
                if (repoItem != null) {
                    val resumed = repoItem.messages.map { it.toUi() }
                    _state.value = _state.value.copy(messages = resumed)
                }
            }
            // Compute the inline error last so it sees the final state.
            refreshInlineError()
        }
    }

    fun selectProvider(provider: ProviderId) {
        val firstModel = ModelCatalog.defaultsFor(provider).firstOrNull()?.modelID ?: ""
        viewModelScope.launch {
            container.userSettings.setCurrent(provider, firstModel)
            applySelection(provider, firstModel)
            // Re-check the API key for the newly selected provider so the
            // empty-state copy, the model pill's "Add a model" CTA, and
            // the "No API key" error path all stay accurate after a
            // provider switch. (init() only sets this for the initial
            // provider.)
            val apiKey = container.secretStore.readApiKey(provider)
            _state.value = _state.value.copy(hasApiKey = !apiKey.isNullOrEmpty())
            refreshInlineError()
        }
    }

    fun selectModel(model: String) {
        val provider = _state.value.provider
        viewModelScope.launch {
            container.userSettings.setCurrent(provider, model)
            _state.value = _state.value.copy(model = model, modelsForProvider = availableModelsFor(provider))
            refreshInlineError()
        }
    }

    fun send(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || _state.value.isStreaming) return
        val provider = _state.value.provider
        val model = _state.value.model
        if (model.isBlank()) {
            _state.value = _state.value.copy(error = "No model selected.")
            return
        }
        val client = container.chatClientFor(provider)
        if (client == null) {
            _state.value = _state.value.copy(error = "Provider $provider has no Android client yet.")
            return
        }

        val now = System.currentTimeMillis()
        val attachedImages = _state.value.attachedImages
        val userMsg = ChatMessage.User(
            text = trimmed,
            timestampMillis = now,
            images = attachedImages,
        )
        val nextMessages = _state.value.messages + userMsg
        _state.value = _state.value.copy(
            messages = nextMessages,
            draft = "",
            isStreaming = true,
            error = null,
            attachedImages = emptyList(),
        )

        // Persist the user message immediately (bug fix: previously the
        // chat only saved on success, so a failed send dropped the user's
        // text out of the sidebar entirely). The user message is marked
        // PENDING; the success / failure paths below update it.
        persistCurrent(nextMessages, lastUserPending = true)

        viewModelScope.launch {
            val apiKey = container.secretStore.readApiKey(provider)
            if (apiKey.isNullOrEmpty()) {
                val failureMessages = markLastUserFailed(
                    nextMessages,
                    "No API key for $provider. Add one in Settings, or use the key icon in the toolbar.",
                )
                _state.value = _state.value.copy(
                    messages = failureMessages,
                    isStreaming = false,
                    error = "No API key for $provider.",
                    attachedImages = attachedImages,
                )
                persistCurrent(failureMessages, lastUserPending = false)
                return@launch
            }
            try {
                val reply = client.chat(
                    model = model,
                    apiKey = apiKey,
                    messages = nextMessages.toProviderMessages(),
                    effort = null,
                )
                val assistantMsg = ChatMessage.Assistant(
                    text = reply,
                    timestampMillis = System.currentTimeMillis(),
                )
                val withReply = markLastUserSent(nextMessages) + assistantMsg
                _state.value = _state.value.copy(
                    messages = withReply,
                    isStreaming = false,
                )
                persistCurrent(withReply, lastUserPending = false)
            } catch (t: Throwable) {
                val reason = t.message ?: t.javaClass.simpleName
                val failureMessages = markLastUserFailed(nextMessages, reason)
                _state.value = _state.value.copy(
                    messages = failureMessages,
                    isStreaming = false,
                    error = reason,
                    // Restore the images so the user can hit Retry (or
                    // edit the message) without re-picking them.
                    attachedImages = attachedImages,
                )
                persistCurrent(failureMessages, lastUserPending = false)
            }
        }
    }

    /**
     * Retry the last failed user message. The last `User` row (whether
     * currently FAILED or PENDING) is re-sent; any prior assistant
     * content for the same user turn is dropped.
     */
    fun retryLast() {
        val messages = _state.value.messages
        val lastUser = messages.lastOrNull { it is ChatMessage.User && it.delivery == ChatMessage.User.Delivery.FAILED }
            ?: return
        send(lastUser.text)
    }

    fun updateDraft(text: String) {
        _state.value = _state.value.copy(draft = text)
    }

    /**
     * Append an image the user just attached (camera capture or gallery
     * pick). The content URI is opened off the main thread, the bytes
     * are base64-encoded, and the resulting `ImageAttachment` is added
     * to the transient `attachedImages` list. Cleared by [send] on a
     * successful dispatch.
     */
    fun attachImage(uri: Uri, contentResolver: ContentResolver) {
        viewModelScope.launch {
            val attachment = withContext(Dispatchers.IO) {
                runCatching { uriToAttachment(uri, contentResolver) }.getOrNull()
            }
            if (attachment != null) {
                _state.value = _state.value.copy(
                    attachedImages = _state.value.attachedImages + attachment,
                )
                refreshInlineError()
            }
        }
    }

    /** Remove a previously-attached image by index. */
    fun removeAttachedImage(index: Int) {
        val list = _state.value.attachedImages
        if (index !in list.indices) return
        _state.value = _state.value.copy(
            attachedImages = list.toMutableList().apply { removeAt(index) },
            inlineError = null, // Removing the last image clears the inline error too.
        )
    }

    fun dismissError() {
        _state.value = _state.value.copy(error = null)
    }

    /**
     * Set the contextual inline error shown above the input field. This
     * is a separate channel from [dismissError] (which clears the top
     * `ErrorBanner`) so the user sees the message where their attention
     * already is — next to the composer — when the issue is about
     * what they just did (e.g. dropped a photo into a model that
     * doesn't accept images).
     */
    fun setInlineError(inlineError: InlineError?) {
        _state.value = _state.value.copy(inlineError = inlineError)
    }

    /**
     * Convenience that recomputes the inline error from the current
     * state — call after every model / provider / attachment change so
     * the banner reflects what the user can actually do right now.
     */
    fun refreshInlineError() {
        val state = _state.value
        _state.value = state.copy(inlineError = computeInlineError(state))
    }

    /** Persist [apiKey] for the current provider. */
    fun saveApiKey(apiKey: String) {
        val provider = _state.value.provider
        viewModelScope.launch {
            container.secretStore.writeApiKey(provider, apiKey)
        }
    }

    private suspend fun applySelection(provider: ProviderId, model: String) {
        _state.value = _state.value.copy(
            provider = provider,
            model = model,
            modelsForProvider = availableModelsFor(provider),
        )
    }

    private fun availableModelsFor(provider: ProviderId): List<AIModel> =
        ModelCatalog.defaultsFor(provider).ifEmpty { ModelCatalog.defaults }

    /**
     * Persist the current transcript for this chat. Lazily mints a new
     * chat id the first time the user sends a message.
     *
     * @param lastUserPending when true, the most recent `User` message
     * is written with `Delivery.PENDING` (we're mid-flight on the API
     * call). On success / failure the caller writes again with the
     * final delivery state.
     */
    private fun persistCurrent(messages: List<ChatMessage>, lastUserPending: Boolean = false) {
        val repo: ChatHistoryRepository = container.chatHistoryRepository
        val id = effectiveChatId ?: repo.startNewChat().also { effectiveChatId = it }
        val persisted = messages.mapIndexed { index, msg ->
            val isLastUser = lastUserPending &&
                index == messages.lastIndex &&
                msg is ChatMessage.User
            msg.toPersisted(markPending = isLastUser)
        }
        repo.saveMessages(id, persisted)
    }

    private fun markLastUserSent(messages: List<ChatMessage>): List<ChatMessage> {
        if (messages.isEmpty()) return messages
        val last = messages.lastIndex
        val tail = messages[last]
        if (tail !is ChatMessage.User) return messages
        val updated = tail.copy(delivery = ChatMessage.User.Delivery.SENT)
        return messages.toMutableList().apply { this[last] = updated }
    }

    private fun markLastUserFailed(messages: List<ChatMessage>, reason: String): List<ChatMessage> {
        if (messages.isEmpty()) return messages
        val last = messages.lastIndex
        val tail = messages[last]
        if (tail !is ChatMessage.User) return messages
        val updated = tail.copy(
            delivery = ChatMessage.User.Delivery.FAILED,
            failureReason = reason,
        )
        return messages.toMutableList().apply { this[last] = updated }
    }

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = (this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY] as RoamSocketApplication)
                ChatViewModel(app.container)
            }
        }

        /**
         * Factory for a chat screen that resumes a specific chat id.
         * Use this from [RootView] when the user taps a sidebar recent.
         */
        fun factoryFor(container: AppContainer, chatId: String?): ViewModelProvider.Factory =
            viewModelFactory {
                initializer { ChatViewModel(container, chatId) }
            }
    }
}

/** Compose-facing state snapshot. */
data class ChatUiState(
    val provider: ProviderId = ProviderId.Anthropic,
    val model: String = "",
    val modelsForProvider: List<AIModel> = emptyList(),
    val messages: List<ChatMessage> = emptyList(),
    val draft: String = "",
    val isStreaming: Boolean = false,
    val error: String? = null,
    /** True once we've confirmed the current provider has an API key configured. */
    val hasApiKey: Boolean = false,
    /**
     * Images the user has attached but not yet sent. Cleared on a
     * successful [ChatViewModel.send]; restored on failure so the
     * user can fix the message and retry without re-picking the photos.
     */
    val attachedImages: List<ProviderChatMessage.ImageAttachment> = emptyList(),
    /**
     * Contextual hint shown right above the input field. Distinct from
     * [error] (the top ErrorBanner) so the user sees the message next
     * to the composer when the issue is about what they just did — e.g.
     * a photo attached to a model that doesn't accept vision.
     */
    val inlineError: InlineError? = null,
)

/**
 * Inline hint rendered between the message list and the input bar.
 * [actionLabel] is optional — when present the row shows a tappable
 * pill that runs [onAction].
 */
data class InlineError(
    val message: String,
    val actionLabel: String? = null,
    val onAction: (() -> Unit)? = null,
)

/** Sealed UI message. Mirrors the iOS `ChatMessage` rendering model. */
sealed interface ChatMessage {
    val text: String
    val timestampMillis: Long

    data class User(
        override val text: String,
        override val timestampMillis: Long = System.currentTimeMillis(),
        /** Delivery state — SENT for the happy path, FAILED on API error, PENDING mid-flight. */
        val delivery: Delivery = Delivery.SENT,
        /** Human-readable reason when [delivery] is FAILED. */
        val failureReason: String? = null,
        /**
         * Vision attachments the user dropped into the composer before
         * sending. The list is in-memory only; we don't persist the raw
         * base64 to disk because chats would balloon. Defaults to empty
         * so existing call sites (tests, history-replay) keep working.
         */
        val images: List<ProviderChatMessage.ImageAttachment> = emptyList(),
    ) : ChatMessage {
        enum class Delivery { SENT, PENDING, FAILED }
    }

    data class Assistant(
        override val text: String,
        override val timestampMillis: Long = System.currentTimeMillis(),
    ) : ChatMessage
}

internal fun ChatMessage.toPersisted(markPending: Boolean = false): PersistedChatMessage = when (this) {
    is ChatMessage.User -> PersistedChatMessage(
        id = "u:$timestampMillis:${text.hashCode()}",
        role = PersistedChatMessage.Role.USER,
        content = text,
        timestampMillis = timestampMillis,
        delivery = when {
            markPending -> PersistedChatMessage.Delivery.PENDING
            delivery == ChatMessage.User.Delivery.FAILED -> PersistedChatMessage.Delivery.FAILED
            else -> PersistedChatMessage.Delivery.SENT
        },
    )
    is ChatMessage.Assistant -> PersistedChatMessage(
        id = "a:$timestampMillis:${text.hashCode()}",
        role = PersistedChatMessage.Role.ASSISTANT,
        content = text,
        timestampMillis = timestampMillis,
    )
}

internal fun PersistedChatMessage.toUi(): ChatMessage = when (role) {
    PersistedChatMessage.Role.USER -> ChatMessage.User(
        text = content,
        timestampMillis = timestampMillis,
        delivery = when (delivery) {
            PersistedChatMessage.Delivery.PENDING -> ChatMessage.User.Delivery.PENDING
            PersistedChatMessage.Delivery.FAILED -> ChatMessage.User.Delivery.FAILED
            PersistedChatMessage.Delivery.SENT -> ChatMessage.User.Delivery.SENT
        },
    )
    PersistedChatMessage.Role.ASSISTANT -> ChatMessage.Assistant(content, timestampMillis)
    PersistedChatMessage.Role.SYSTEM -> ChatMessage.Assistant(content, timestampMillis)
}

internal fun List<ChatMessage>.toProviderMessages(): List<ProviderChatMessage> = map { msg ->
    when (msg) {
        is ChatMessage.User -> ProviderChatMessage(
            role = ProviderChatMessage.Role.USER,
            content = msg.text,
            images = msg.images,
        )
        is ChatMessage.Assistant -> ProviderChatMessage(
            role = ProviderChatMessage.Role.ASSISTANT,
            content = msg.text,
        )
    }
}

/**
 * Read the bytes behind a content URI (camera capture output or gallery
 * pick) and base64-encode them into a [ProviderChatMessage.ImageAttachment].
 * Returns null on any failure (caller should swallow the error and
 * surface a snackbar in a follow-up PR).
 */
private fun uriToAttachment(
    uri: Uri,
    contentResolver: ContentResolver,
): ProviderChatMessage.ImageAttachment? {
    val mime = contentResolver.getType(uri) ?: "image/jpeg"
    // Reject non-image MIME types — gallery picker can return videos / PDFs.
    if (!mime.startsWith("image/")) return null
    val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
    return ProviderChatMessage.ImageAttachment(
        mimeType = mime,
        base64Data = Base64.encodeToString(bytes, Base64.NO_WRAP),
    )
}

/**
 * Heuristic vision-capability table. The real source of truth lives in
 * the iOS `ModelCatalog`; once we move the per-model `supportsVision`
 * flag into `AIModel` (next pass), this collapses to `model.supportsVision`.
 *
 * Today the only provider that is *known* to be vision-less in this
 * catalog is MiniMax (no MiniMax model currently accepts images).
 * Everyone else — Anthropic, OpenAI, Google, Groq, OpenRouter, xAI,
 * Mistral — has at least one vision-capable model in their default
 * set, so we treat the provider as vision-capable. The list is
 * explicitly enumerated (instead of "all except MiniMax") so that
 * adding a new provider forces a deliberate vision decision.
 */
private fun providerSupportsVision(provider: ProviderId): Boolean = when (provider) {
    ProviderId.MiniMax -> false
    ProviderId.Anthropic,
    ProviderId.OpenAI,
    ProviderId.Google,
    ProviderId.Groq,
    ProviderId.OpenRouter,
    ProviderId.XAI,
    ProviderId.Mistral,
    ProviderId.LocalMetal -> true
    is ProviderId.Custom -> true
}

/**
 * Inspect the current state and return the inline error to show above
 * the input bar, or null when the user is in a happy path. Called by
 * [ChatViewModel.refreshInlineError] after every model / provider /
 * attachment change.
 */
private fun computeInlineError(state: ChatUiState): InlineError? {
    if (state.attachedImages.isEmpty()) return null
    if (providerSupportsVision(state.provider)) return null
    val message = when (state.provider) {
        ProviderId.MiniMax ->
            "${state.provider.displayName} doesn't ship a vision model in this catalog. Try Anthropic, OpenAI, or Google."
        else ->
            "${state.provider.displayName} doesn't support images in this catalog. Try a vision-capable model."
    }
    return InlineError(message = message, actionLabel = null, onAction = null)
}
