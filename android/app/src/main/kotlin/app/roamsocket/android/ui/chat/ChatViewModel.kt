package app.roamsocket.android.ui.chat

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
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
 */
class ChatViewModel(
    private val container: AppContainer,
) : ViewModel() {

    private val _state = MutableStateFlow(ChatUiState())
    val state: StateFlow<ChatUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            val provider = container.userSettings.currentProvider.first()
            val model = container.userSettings.currentModel.first()
            applySelection(provider, model)
        }
    }

    fun selectProvider(provider: ProviderId) {
        // Pick the first default model for the new provider.
        val firstModel = ModelCatalog.defaultsFor(provider).firstOrNull()?.modelID ?: ""
        viewModelScope.launch {
            container.userSettings.setCurrent(provider, firstModel)
            applySelection(provider, firstModel)
        }
    }

    fun selectModel(model: String) {
        val provider = _state.value.provider
        viewModelScope.launch {
            container.userSettings.setCurrent(provider, model)
            _state.value = _state.value.copy(model = model, modelsForProvider = availableModelsFor(provider))
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

        val nextMessages = _state.value.messages + ChatMessage.User(trimmed)
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
                _state.value = _state.value.copy(
                    messages = _state.value.messages + ChatMessage.Assistant(reply),
                    isStreaming = false,
                )
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

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = (this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY] as RoamSocketApplication)
                ChatViewModel(app.container)
            }
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
    data class User(val text: String) : ChatMessage
    data class Assistant(val text: String) : ChatMessage
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
