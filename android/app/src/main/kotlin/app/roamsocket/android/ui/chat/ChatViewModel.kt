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
import app.roamsocket.android.data.ToolAccessLevel
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

            // Restore the Add-to-Chat toggles + tool access level from
            // DataStore. They're independent of provider / model so we
            // re-load on every screen open.
            _state.value = _state.value.copy(
                researchEnabled = container.userSettings.researchEnabled.first(),
                webSearchEnabled = container.userSettings.webSearchEnabled.first(),
                locationEnabled = container.userSettings.locationEnabled.first(),
                toolAccess = container.userSettings.toolAccess.first(),
            )

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
        val attachedFiles = _state.value.attachedFiles
        val userMsg = ChatMessage.User(
            text = trimmed,
            timestampMillis = now,
            images = attachedImages,
            files = attachedFiles,
        )
        val nextMessages = _state.value.messages + userMsg
        _state.value = _state.value.copy(
            messages = nextMessages,
            draft = "",
            isStreaming = true,
            error = null,
            attachedImages = emptyList(),
            attachedFiles = emptyList(),
        )

        // Persist the user message immediately (bug fix: previously the
        // chat only saved on success, so a failed send dropped the user's
        // text out of the sidebar entirely). The user message is marked
        // PENDING; the success / failure paths below update it.
        persistCurrent(nextMessages, lastUserPending = true)

        // Build the prompt augmentation based on the Add-to-Chat toggles.
        val prompt = buildAddToChatPrompt(
            text = trimmed,
            state = _state.value,
        )

        viewModelScope.launch {
            val apiKey = container.secretStore.readApiKey(provider)
            if (apiKey.isNullOrEmpty()) {
                val failureMessages = markLastUserFailed(
                    nextMessages,
                    "No API key for $provider. Add one in Settings, or use the key icon in the toolbar.",
                )
                // The user may have attached new images / files while the key
                // lookup was happening; preserve those AND the ones the failed
                // send used so the next attempt doesn't drop user work.
                val liveState = _state.value
                _state.value = liveState.copy(
                    messages = failureMessages,
                    isStreaming = false,
                    error = "No API key for $provider.",
                    attachedImages = liveState.attachedImages + attachedImages,
                    attachedFiles = liveState.attachedFiles + attachedFiles,
                )
                persistCurrent(failureMessages, lastUserPending = false)
                return@launch
            }
            try {
                val reply = client.chat(
                    model = model,
                    apiKey = apiKey,
                    messages = nextMessages.toProviderMessages(prompt = prompt),
                    effort = null,
                    webSearchQuery = if (_state.value.webSearchEnabled) trimmed else null,
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
                // Restore the captured attachments AND keep any new ones the
                // user added during the in-flight request, so Retry (or a
                // manual resend) can include everything they prepared.
                val liveState = _state.value
                _state.value = liveState.copy(
                    messages = failureMessages,
                    isStreaming = false,
                    error = reason,
                    attachedImages = liveState.attachedImages + attachedImages,
                    attachedFiles = liveState.attachedFiles + attachedFiles,
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

    // ----- Add to Chat sheet (port #12) -----

    /**
     * Attach a list of files picked from the device's Storage Access
     * Framework. Each URI is read off the main thread, classified, and
     * either decoded to text (for text-shaped MIME types) or recorded as
     * a binary skip. Files that fail to read are silently dropped; the
     * caller surfaces a snackbar in a follow-up.
     */
    fun addFiles(uris: List<Uri>, contentResolver: ContentResolver) {
        if (uris.isEmpty()) return
        viewModelScope.launch {
            val attachments: List<ProviderChatMessage.FileAttachment> = withContext(Dispatchers.IO) {
                uris.mapNotNull { uri -> uriToFileAttachment(uri, contentResolver) }
            }
            if (attachments.isNotEmpty()) {
                _state.value = _state.value.copy(
                    attachedFiles = _state.value.attachedFiles + attachments,
                )
            }
        }
    }

    /** Remove a previously-attached file by index. */
    fun removeAttachedFile(index: Int) {
        val list = _state.value.attachedFiles
        if (index !in list.indices) return
        _state.value = _state.value.copy(
            attachedFiles = list.toMutableList().apply { removeAt(index) },
        )
    }

    /** Toggle the multi-query research mode. Persisted across launches. */
    fun setResearchEnabled(enabled: Boolean) {
        _state.value = _state.value.copy(researchEnabled = enabled)
        viewModelScope.launch { container.userSettings.setResearchEnabled(enabled) }
    }

    /** Toggle the provider-native web search. Persisted across launches. */
    fun setWebSearchEnabled(enabled: Boolean) {
        _state.value = _state.value.copy(webSearchEnabled = enabled)
        viewModelScope.launch { container.userSettings.setWebSearchEnabled(enabled) }
    }

    /** Toggle sharing approximate location with the model. */
    fun setLocationEnabled(enabled: Boolean) {
        _state.value = _state.value.copy(locationEnabled = enabled)
        viewModelScope.launch { container.userSettings.setLocationEnabled(enabled) }
    }

    /** Update the desktop agent's tool access level. */
    fun setToolAccess(level: ToolAccessLevel) {
        _state.value = _state.value.copy(toolAccess = level)
        viewModelScope.launch { container.userSettings.setToolAccess(level) }
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
    /**
     * Files the user has attached but not yet sent (port #12, from
     * the Add to Chat sheet → "Add files"). Cleared on a successful
     * [ChatViewModel.send]; restored on failure for retry.
     */
    val attachedFiles: List<ProviderChatMessage.FileAttachment> = emptyList(),
    /**
     * Contextual hint shown right above the input field. Distinct from
     * [error] (the top ErrorBanner) so the user sees the message next
     * to the composer when the issue is about what they just did — e.g.
     * a photo attached to a model that doesn't accept vision.
     */
    val inlineError: InlineError? = null,
    // ----- Add to Chat (port #12) -----
    /** Multi-query research mode. */
    val researchEnabled: Boolean = false,
    /** Provider-native web search. */
    val webSearchEnabled: Boolean = false,
    /** Share approximate location with the model. */
    val locationEnabled: Boolean = false,
    /** Desktop agent's tool access level (Auto / Read-only / Full). */
    val toolAccess: ToolAccessLevel = ToolAccessLevel.Auto,
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
        /**
         * File attachments from the Add to Chat sheet (port #12). In-memory
         * for the same reason as `images`. The contents are inlined into
         * the user message text at send time so the model sees a single
         * prompt rather than a parallel structure.
         */
        val files: List<ProviderChatMessage.FileAttachment> = emptyList(),
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

/**
 * Convert the in-memory transcript into the provider's wire format.
 *
 * - File attachments are inlined as `[Attached file: name]` blocks
 *   immediately under the user message body. The model's own context
 *   window decides what to do with them.
 * - The [prompt] suffix (built by [buildAddToChatPrompt]) is appended
 *   to the *last* user message only. This keeps prior turns verbatim
 *   while still injecting the live Add-to-Chat toggles into the
 *   outgoing turn.
 */
internal fun List<ChatMessage>.toProviderMessages(prompt: String = ""): List<ProviderChatMessage> = mapIndexed { idx, msg ->
    when (msg) {
        is ChatMessage.User -> {
            val isLast = idx == lastIndex
            val fileBlocks = msg.files.joinToString(separator = "\n\n") { f ->
                if (f.skippedBinary) {
                    "[Attached file: ${f.displayName} (binary content skipped — type: ${f.mimeType})]"
                } else {
                    "[Attached file: ${f.displayName} (${f.mimeType})]\n```\n${f.text}\n```"
                }
            }
            val body = buildString {
                append(msg.text)
                if (fileBlocks.isNotEmpty()) {
                    append("\n\n")
                    append(fileBlocks)
                }
                if (isLast && prompt.isNotEmpty()) {
                    append("\n\n")
                    append(prompt)
                }
            }
            ProviderChatMessage(
                role = ProviderChatMessage.Role.USER,
                content = body,
                images = msg.images,
            )
        }
        is ChatMessage.Assistant -> ProviderChatMessage(
            role = ProviderChatMessage.Role.ASSISTANT,
            content = msg.text,
        )
    }
}

/**
 * Build the trailing prompt block applied to the outgoing user message
 * based on the Add to Chat toggles + the current tool access level. Kept
 * here (rather than the iOS sheet) so the wire format lives in one
 * place. Empty string when nothing's toggled.
 */
internal fun buildAddToChatPrompt(text: String, state: ChatUiState): String = buildString {
    if (state.researchEnabled) {
        append("[Research mode: use multi-query web search and Wikipedia for deeper answers.]\n")
    }
    if (state.webSearchEnabled) {
        append("[Web search enabled: search the web for the latest information and cite sources.]\n")
    }
    if (state.locationEnabled) {
        // The desktop server resolves the precise location once we ship
        // location services; for now the chat client doesn't have a
        // geocoder, so we hint that location context is on. The user
        // will see the toggle in Settings and can re-configure.
        append("[Location sharing enabled. Approximate location will be appended by the server when the desktop agent is paired.]\n")
    }
    if (state.toolAccess != ToolAccessLevel.Auto) {
        append("[Tool access: ${state.toolAccess.display} — ${state.toolAccess.description}]\n")
    }
}.trimEnd()

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
 * Read a content URI and return a [ProviderChatMessage.FileAttachment].
 * Used by the Add to Chat sheet's "Add files" entry (port #12).
 *
 * For text-shaped MIME types (`text/...`, JSON, XML, source files) we
 * decode the bytes as UTF-8 (best-effort) and truncate to
 * [ProviderChatMessage.FileAttachment.MAX_TEXT_BYTES]. For anything else
 * we record a `skippedBinary` placeholder so the model still sees the
 * file name in the prompt.
 */
private fun uriToFileAttachment(
    uri: Uri,
    contentResolver: ContentResolver,
): ProviderChatMessage.FileAttachment? {
    val mime = contentResolver.getType(uri) ?: "application/octet-stream"
    val displayName = queryDisplayName(uri, contentResolver) ?: uri.lastPathSegment ?: "file"
    val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
    val isText = mime.startsWith("text/") ||
        mime in setOf("application/json", "application/xml", "application/javascript", "application/x-yaml")
    if (!isText) {
        return ProviderChatMessage.FileAttachment(
            displayName = displayName,
            mimeType = mime,
            text = "",
            skippedBinary = true,
        )
    }
    val cap = ProviderChatMessage.FileAttachment.MAX_TEXT_BYTES
    val truncated = bytes.size > cap
    val text = String(bytes, charset = Charsets.UTF_8).let {
        if (truncated) it.substring(0, cap) + "\n…[truncated]" else it
    }
    return ProviderChatMessage.FileAttachment(
        displayName = displayName,
        mimeType = mime,
        text = text,
        skippedBinary = false,
    )
}

private fun queryDisplayName(uri: Uri, contentResolver: ContentResolver): String? {
    return runCatching {
        contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) cursor.getString(idx) else null
                } else null
            }
    }.getOrNull()
}

/**
 * Per-model vision capability lookup against the local
 * [ChatUiState.modelsForProvider] snapshot. Returns:
 *  - `true` when the currently selected [AIModel] is vision-capable.
 *  - `null` when the model isn't in the local list (e.g. the user
 *    has a custom model id or the live listing hasn't been loaded
 *    yet). The chat UI treats `null` as "send and let the provider
 *    decide" rather than guessing.
 */
private fun selectedModelSupportsVision(state: ChatUiState): Boolean? =
    state.modelsForProvider.firstOrNull { it.modelID == state.model }?.supportsVision

@Suppress("unused")
private fun _displayNameAnchor(fn: (android.net.Uri, android.content.ContentResolver) -> String?) = fn  // keep the helper reachable

/**
 * Inspect the current state and return the inline error to show above
 * the input bar, or null when the user is in a happy path. Called by
 * [ChatViewModel.refreshInlineError] after every model / provider /
 * attachment change.
 *
 * Decision is per-model (not per-provider): we look up the currently
 * selected [AIModel] in [ChatUiState.modelsForProvider] and read its
 * `supportsVision` flag, which the providers populate from the live
 * `/models` API (OpenRouter's `architecture.input_modalities`) or
 * from a per-provider id-based heuristic (see [ModelCapabilities]).
 * Unknown models (e.g. the model is in the live listing but not in
 * the local list) default to "supported" so the user gets a clear
 * 400 error from the provider rather than a misleading local hint.
 */
private fun computeInlineError(state: ChatUiState): InlineError? {
    if (state.attachedImages.isEmpty()) return null
    val selectedModel = state.modelsForProvider.firstOrNull { it.modelID == state.model }
    if (selectedModel?.supportsVision == true) return null
    val message = when {
        selectedModel != null ->
            "${selectedModel.displayName} doesn't accept images. Try a vision-capable model like Claude 3.5 Sonnet, GPT-4o, or Gemini 2.0 Flash."
        else ->
            "${state.provider.displayName} has no vision-capable model in this catalog. Try Anthropic, OpenAI, or Google."
    }
    return InlineError(message = message, actionLabel = null, onAction = null)
}
