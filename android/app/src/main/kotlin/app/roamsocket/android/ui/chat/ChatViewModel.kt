package app.roamsocket.android.ui.chat

import android.app.Application
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

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
            // Resume the persisted transcript when the screen opens on an
            // existing chat id, and prefer the chat's saved (provider, model)
            // over the global default (port #9: per-chat model selection).
            val id = effectiveChatId
            val repoItem = id?.let { container.chatHistoryRepository.snapshot().firstOrNull { c -> c.id == it } }
            val (provider, model) = if (repoItem?.hasModelOverride == true) {
                val p = repoItem.resolvedProvider!!
                val m = repoItem.selectedModel!!
                p to m
            } else {
                container.userSettings.currentProvider.first() to container.userSettings.currentModel.first()
            }
            applySelection(provider, model)

            if (id != null && repoItem != null) {
                val resumed = repoItem.messages.map { it.toUi() }
                _state.value = _state.value.copy(messages = resumed)
            }
        }
    }

    fun selectProvider(provider: ProviderId) {
        val firstModel = ModelCatalog.defaultsFor(provider).firstOrNull()?.modelID ?: ""
        viewModelScope.launch {
            container.userSettings.setCurrent(provider, firstModel)
            applySelection(provider, firstModel)
            persistModelForActiveChat(provider, firstModel)
        }
    }

    fun selectModel(model: String) {
        val provider = _state.value.provider
        viewModelScope.launch {
            container.userSettings.setCurrent(provider, model)
            _state.value = _state.value.copy(model = model, modelsForProvider = availableModelsFor(provider))
            persistModelForActiveChat(provider, model)
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
        val userMsg = ChatMessage.User(trimmed, timestampMillis = now)
        val nextMessages = _state.value.messages + userMsg
        _state.value = _state.value.copy(
            messages = nextMessages,
            draft = "",
            isStreaming = true,
            error = null,
        )

        viewModelScope.launch {
            val apiKey = container.secretStore.readApiKey(provider)
            if (apiKey.isNullOrEmpty()) {
                _state.value = _state.value.copy(
                    isStreaming = false,
                    error = "No API key for $provider. Tap the key icon to add one.",
                )
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
                val withReply = nextMessages + assistantMsg
                _state.value = _state.value.copy(
                    messages = withReply,
                    isStreaming = false,
                )
                persistCurrent(withReply)
            } catch (t: Throwable) {
                _state.value = _state.value.copy(
                    isStreaming = false,
                    error = t.message ?: t.javaClass.simpleName,
                )
            }
        }
    }

    fun updateDraft(text: String) {
        _state.value = _state.value.copy(draft = text)
    }

    fun dismissError() {
        _state.value = _state.value.copy(error = null)
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
     */
    private fun persistCurrent(messages: List<ChatMessage>) {
        val repo: ChatHistoryRepository = container.chatHistoryRepository
        val id = effectiveChatId ?: repo.startNewChat().also { effectiveChatId = it }
        val persisted = messages.map { it.toPersisted() }
        repo.saveMessages(id, persisted)
    }

    /**
     * Save the per-chat model selection. Mints a chat id lazily so the
     * picker "sticks" to a chat the user hasn't sent a message in yet.
     */
    private fun persistModelForActiveChat(provider: ProviderId, model: String) {
        val repo: ChatHistoryRepository = container.chatHistoryRepository
        val id = effectiveChatId ?: repo.startNewChat().also { effectiveChatId = it }
        repo.setModel(id, provider, model)
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
)

/** Sealed UI message. Mirrors the iOS `ChatMessage` rendering model. */
sealed interface ChatMessage {
    val text: String
    val timestampMillis: Long

    data class User(
        override val text: String,
        override val timestampMillis: Long = System.currentTimeMillis(),
    ) : ChatMessage

    data class Assistant(
        override val text: String,
        override val timestampMillis: Long = System.currentTimeMillis(),
    ) : ChatMessage
}

private fun ChatMessage.toPersisted(): PersistedChatMessage = when (this) {
    is ChatMessage.User -> PersistedChatMessage(
        id = "u:$timestampMillis:${text.hashCode()}",
        role = PersistedChatMessage.Role.USER,
        content = text,
        timestampMillis = timestampMillis,
    )
    is ChatMessage.Assistant -> PersistedChatMessage(
        id = "a:$timestampMillis:${text.hashCode()}",
        role = PersistedChatMessage.Role.ASSISTANT,
        content = text,
        timestampMillis = timestampMillis,
    )
}

private fun PersistedChatMessage.toUi(): ChatMessage = when (role) {
    PersistedChatMessage.Role.USER -> ChatMessage.User(content, timestampMillis)
    PersistedChatMessage.Role.ASSISTANT -> ChatMessage.Assistant(content, timestampMillis)
    PersistedChatMessage.Role.SYSTEM -> ChatMessage.Assistant(content, timestampMillis)
}

internal fun List<ChatMessage>.toProviderMessages(): List<ProviderChatMessage> = map { msg ->
    when (msg) {
        is ChatMessage.User -> ProviderChatMessage(
            role = ProviderChatMessage.Role.USER,
            content = msg.text,
        )
        is ChatMessage.Assistant -> ProviderChatMessage(
            role = ProviderChatMessage.Role.ASSISTANT,
            content = msg.text,
        )
    }
}
