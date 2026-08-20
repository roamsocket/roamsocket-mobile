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
            refreshLiveModels(provider, apiKey)

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
        }
    }

    fun selectProvider(provider: ProviderId) {
        viewModelScope.launch {
            val firstModel = ModelCatalog.defaultsFor(provider).firstOrNull()?.modelID ?: ""
            container.userSettings.setCurrent(provider, firstModel)
            applySelection(provider, firstModel)
            // Re-check the API key for the newly selected provider so the
            // empty-state copy, the model pill's "Add a model" CTA, and
            // the "No API key" error path all stay accurate after a
            // provider switch. (init() only sets this for the initial
            // provider.)
            val apiKey = container.secretStore.readApiKey(provider)
            _state.value = _state.value.copy(hasApiKey = !apiKey.isNullOrEmpty())
            refreshLiveModels(provider, apiKey)
        }
    }

    fun selectModel(model: String) {
        val provider = _state.value.provider
        viewModelScope.launch {
            container.userSettings.setCurrent(provider, model)
            _state.value = _state.value.copy(model = model, modelsForProvider = availableModelsFor(provider))
        }
    }

    /**
     * Pull the live model list for [provider] from the upstream `/v1/models`
     * endpoint. The picker uses this as the source of truth — the static
     * `ModelCatalog` is only a fallback when the live fetch fails or the
     * provider has no API to call.
     *
     * State semantics on [ChatUiState.liveModelsForProvider]:
     * - `null` — fetch has not completed yet (or is in flight)
     * - `[]`   — fetch completed, returned no models
     * - `[…]`  — fetch completed, these are the usable models
     */
    private fun refreshLiveModels(provider: ProviderId, apiKey: String?) {
        // Surface "still loading" so the picker can render an explicit
        // "Loading models…" state instead of pretending nothing is there.
        _state.value = _state.value.copy(liveModelsForProvider = null)
        viewModelScope.launch {
            val client = container.chatClientFor(provider)
            // Local providers (Metal, Apple Foundation, custom-without-base-URL)
            // don't expose a listModels endpoint; treat them as "no live list"
            // and let the static catalog drive the picker.
            if (client == null || apiKey.isNullOrEmpty()) {
                _state.value = _state.value.copy(liveModelsForProvider = emptyList())
                return@launch
            }
            val live = runCatching { client.listModels(apiKey) }
                .getOrElse { emptyList() }
            _state.value = _state.value.copy(liveModelsForProvider = live)
        }
    }

    /**
     * Public hook used by the UI to retry a live model fetch — e.g. after the
     * user pastes a fresh API key in the dialog. Exposed as its own method so
     * the dialog "Save" path can call it without duplicating the fetch logic.
     */
    fun retryLiveModelsFetch() {
        val provider = _state.value.provider
        viewModelScope.launch {
            refreshLiveModels(provider, container.secretStore.readApiKey(provider))
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
            }
        }
    }

    /** Remove a previously-attached image by index. */
    fun removeAttachedImage(index: Int) {
        val list = _state.value.attachedImages
        if (index !in list.indices) return
        _state.value = _state.value.copy(
            attachedImages = list.toMutableList().apply { removeAt(index) },
        )
    }

    fun dismissError() {
        _state.value = _state.value.copy(error = null)
    }

    /** Persist [apiKey] for the current provider. */
    fun saveApiKey(apiKey: String) {
        val provider = _state.value.provider
        viewModelScope.launch {
            container.secretStore.writeApiKey(provider, apiKey)
            _state.value = _state.value.copy(hasApiKey = apiKey.isNotEmpty())
            refreshLiveModels(provider, apiKey)
        }
    }

    private suspend fun applySelection(provider: ProviderId, model: String) {
        _state.value = _state.value.copy(
            provider = provider,
            model = model,
            modelsForProvider = availableModelsFor(provider),
        )
    }

    private fun availableModelsFor(provider: ProviderId): List<AIModel> {
        // Prefer the live list when it has anything; fall back to the static
        // catalog so the picker isn't empty when the upstream is unreachable
        // (e.g. offline / 401). The picker itself gates on
        // `liveModelsForProvider` to decide whether to render the "Add a
        // model" CTA — this list is just the data the dropdown iterates over.
        val live = _state.value.liveModelsForProvider
        if (!live.isNullOrEmpty()) return live
        return ModelCatalog.defaultsFor(provider).ifEmpty { ModelCatalog.defaults }
    }

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
    /**
     * Models the upstream `/v1/models` endpoint returned for [provider]. The
     * model picker renders an "Add a model" CTA when this is `null`
     * (loading) or `[]` (fetch returned nothing / 401'd) so the user always
     * knows whether they're seeing a real list or a static fallback.
     */
    val liveModelsForProvider: List<AIModel>? = null,
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
