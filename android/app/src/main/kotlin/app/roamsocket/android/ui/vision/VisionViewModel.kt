package app.roamsocket.android.ui.vision

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
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ModelCapabilities
import app.roamsocket.core.providers.ModelCatalog
import app.roamsocket.core.providers.ProviderChatMessage
import app.roamsocket.core.providers.ProviderId
import app.roamsocket.core.providers.ProviderRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Drives the Vision mode screen: a full-screen camera viewfinder + a
 * "pick from gallery" entry + capture-and-analyze with a vision-capable
 * model + a follow-up chat thread that keeps the photo in context.
 *
 * The view-model is intentionally self-contained — it doesn't touch the
 * chat history repository. A user can take a photo, ask follow-up
 * questions, then exit; the thread is ephemeral, just like the iOS
 * `VisionView` flow.
 *
 * The wire format reuses [ProviderChatMessage.ImageAttachment] from the
 * existing chat composer (port #7), so the same provider clients
 * (`OpenAICompatibleProvider`, `AnthropicProvider`, `GoogleProvider`)
 * carry the image without any new code on the network side.
 */
class VisionViewModel(
    private val container: AppContainer,
) : ViewModel() {

    /**
     * State of the Vision flow. Mirrors the iOS `VisionViewModel.Phase`
     * enum but collapses `.capturing` into `.analyzing` since on Android
     * the camera is its own component (no in-process preview to freeze).
     */
    enum class Phase {
        /** No image yet. Camera + gallery are available. */
        Live,
        /** Image is set; we are waiting on the vision model. */
        Analyzing,
        /** Image + first analysis are on screen. Follow-ups allowed. */
        Result,
        /** Analysis failed; show the error but allow retake / retry. */
        Failed,
    }

    /** A single message in the post-capture conversation. */
    data class Turn(
        val role: Role,
        val text: String,
        val isError: Boolean = false,
    ) {
        enum class Role { User, Assistant }
    }

    /** Full UI state. */
    data class UiState(
        val phase: Phase = Phase.Live,
        /** Persisted bytes of the frozen photo (JPEG). */
        val imageBytes: ByteArray? = null,
        val imageMime: String = "image/jpeg",
        /** First analysis text (or last follow-up) — the "headline" reply. */
        val analysisText: String = "",
        /** Full thread; first entry is the analysis, then alternating user/assistant. */
        val turns: List<Turn> = emptyList(),
        val draft: String = "",
        /** The model the Vision screen will use. Filters to vision-capable. */
        val selectedModel: AIModel? = null,
        /** All vision-capable models across the live + default catalogs. */
        val visionModels: List<AIModel> = emptyList(),
        /** True while we are waiting for the model's first response. */
        val isAnalyzing: Boolean = false,
        /** True while a follow-up reply is in flight. */
        val isReplying: Boolean = false,
        /** User-facing error to surface inline (e.g. "no API key for $provider"). */
        val errorMessage: String? = null,
        /** True if the current provider has no API key (drives a CTA). */
        val missingApiKey: Boolean = false,
        /** The analysis mode used for the last (or current) capture. */
        val selectedMode: Int = 0, // VisionMode index: 0=GENERAL, 1=TRANSCRIBE, 2=IDENTIFY
    ) {
        /**
         * Equality is content-based for [imageBytes] (ByteArray equality
         * is reference-based by default). Compose skips image comparison
         * for the typical no-image-diff path, so the cost only matters
         * on actual changes.
         */
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is UiState) return false
            val sameImage = when {
                imageBytes == null && other.imageBytes == null -> true
                imageBytes == null || other.imageBytes == null -> false
                else -> imageBytes.contentEquals(other.imageBytes)
            }
            return phase == other.phase &&
                sameImage &&
                imageMime == other.imageMime &&
                analysisText == other.analysisText &&
                turns == other.turns &&
                draft == other.draft &&
                selectedModel == other.selectedModel &&
                visionModels == other.visionModels &&
                isAnalyzing == other.isAnalyzing &&
                isReplying == other.isReplying &&
                errorMessage == other.errorMessage &&
                missingApiKey == other.missingApiKey &&
                selectedMode == other.selectedMode
        }

        override fun hashCode(): Int {
            var result = phase.hashCode()
            result = 31 * result + (imageBytes?.contentHashCode() ?: 0)
            result = 31 * result + imageMime.hashCode()
            result = 31 * result + analysisText.hashCode()
            result = 31 * result + turns.hashCode()
            result = 31 * result + draft.hashCode()
            result = 31 * result + (selectedModel?.hashCode() ?: 0)
            result = 31 * result + visionModels.hashCode()
            result = 31 * result + isAnalyzing.hashCode()
            result = 31 * result + isReplying.hashCode()
            result = 31 * result + (errorMessage?.hashCode() ?: 0)
            result = 31 * result + missingApiKey.hashCode()
            result = 31 * result + selectedMode.hashCode()
            return result
        }
    }

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    /** Provider-facing history used to keep the photo in context for follow-ups. */
    private var providerMessages: MutableList<ProviderChatMessage> = mutableListOf()
    private var pendingJob: Job? = null

    init {
        viewModelScope.launch {
            // Honour the user's last provider/model pick, then re-validate
            // it is still vision-capable. If not, fall back to a known
            // vision model on the same provider, else the first vision
            // model from any configured provider.
            val provider = container.userSettings.currentProvider.first()
            val modelID = container.userSettings.currentModel.first()
            val apiKey = container.secretStore.readApiKey(provider)
            val liveModels = loadLiveVisionModels(provider, apiKey)
            val fallback = liveModels.firstOrNull { it.provider == provider }
                ?: liveModels.firstOrNull()
            val preferred = fallback?.let { preferred ->
                val initial = AIModel(provider, modelID, modelID, supportsVision = true)
                ModelCapabilities.preferredVisionModel(liveModels, current = initial)
                    ?: preferred
            }
            val selected = preferred ?: fallback
            val missing = apiKey.isNullOrEmpty()
            _state.value = _state.value.copy(
                selectedModel = selected,
                visionModels = liveModels,
                missingApiKey = missing && liveModels.isEmpty(),
                errorMessage = if (missing) MISSING_KEY_HINT else null,
            )
        }
    }

    // ---------------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------------

    /** User picked a model from the picker sheet. */
    fun selectModel(model: AIModel) {
        _state.value = _state.value.copy(selectedModel = model)
        // Persist the new pick so other screens see it too.
        viewModelScope.launch {
            container.userSettings.setCurrent(model.provider, model.modelID)
        }
    }

    /** User updated the follow-up text field. */
    fun updateDraft(text: String) {
        _state.value = _state.value.copy(draft = text)
    }

    /** A photo arrived from camera or gallery. Move to analyzing + run. */
    fun onImageReady(bytes: ByteArray, mime: String, mode: app.roamsocket.android.ui.vision.VisionMode) {
        // Ignore taps while we are mid-analysis to avoid two concurrent calls.
        if (_state.value.isAnalyzing || _state.value.isReplying) return
        val model = _state.value.selectedModel ?: run {
            _state.value = _state.value.copy(
                errorMessage = "Pick a vision-capable model first.",
            )
            return
        }
        // Snapshot everything we need so we can release the lock immediately.
        pendingJob?.cancel()
        providerMessages.clear()
        providerMessages += ProviderChatMessage(
            role = ProviderChatMessage.Role.USER,
            content = mode.systemInstruction,
            images = listOf(toAttachment(bytes, mime)),
        )
        _state.value = _state.value.copy(
            phase = Phase.Analyzing,
            imageBytes = bytes,
            imageMime = mime,
            analysisText = "",
            turns = emptyList(),
            draft = "",
            errorMessage = null,
            missingApiKey = false,
            isAnalyzing = true,
            selectedMode = mode.ordinal,
        )

        pendingJob = viewModelScope.launch {
            val apiKey = container.secretStore.readApiKey(model.provider).orEmpty()
            if (apiKey.isEmpty()) {
                _state.value = _state.value.copy(
                    phase = Phase.Failed,
                    errorMessage = "No API key for ${model.provider.displayName}. Add one in Settings.",
                    missingApiKey = true,
                    isAnalyzing = false,
                )
                return@launch
            }
            runChat(model, apiKey, isFirstTurn = true)
        }
    }

    /** Send the follow-up question with the same image still attached. */
    fun sendFollowUp() {
        val s = _state.value
        val text = s.draft.trim()
        if (text.isEmpty() || s.isReplying || s.isAnalyzing) return
        val model = s.selectedModel ?: return
        val bytes = s.imageBytes ?: return
        providerMessages += ProviderChatMessage(
            role = ProviderChatMessage.Role.USER,
            content = text,
            images = listOf(toAttachment(bytes, s.imageMime)),
        )
        _state.value = s.copy(
            turns = s.turns + Turn(Turn.Role.User, text),
            draft = "",
            isReplying = true,
        )
        pendingJob = viewModelScope.launch {
            val apiKey = container.secretStore.readApiKey(model.provider).orEmpty()
            if (apiKey.isEmpty()) {
                _state.value = _state.value.copy(
                    errorMessage = "No API key for ${model.provider.displayName}. Add one in Settings.",
                    missingApiKey = true,
                    isReplying = false,
                )
                return@launch
            }
            runChat(model, apiKey, isFirstTurn = false)
        }
    }

    /** Throw away the captured image and return to the live viewfinder. */
    fun retake() {
        pendingJob?.cancel()
        pendingJob = null
        providerMessages.clear()
        _state.value = _state.value.copy(
            phase = Phase.Live,
            imageBytes = null,
            analysisText = "",
            turns = emptyList(),
            draft = "",
            errorMessage = null,
            isAnalyzing = false,
            isReplying = false,
        )
    }

    /** Same image, same model — useful after picking a new vision model. */
    fun retry() {
        val s = _state.value
        val bytes = s.imageBytes ?: return
        val mode = app.roamsocket.android.ui.vision.VisionMode.fromIndex(s.selectedMode)
        onImageReady(bytes, s.imageMime, mode)
    }

    /** Dismiss the inline error pill. */
    fun dismissError() {
        _state.value = _state.value.copy(errorMessage = null)
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /**
     * Run the chat client and dispatch the assistant reply into [_state].
     * Honours [isFirstTurn] to set the headline analysis text on the first
     * response vs. the follow-up case (where we only append a turn).
     */
    private suspend fun runChat(model: AIModel, apiKey: String, isFirstTurn: Boolean) {
        val client = ProviderRegistry.client(model.provider, container.httpClient)
        if (client == null) {
            val msg = "No client registered for ${model.provider.displayName}."
            applyFailure(msg, isFirstTurn = isFirstTurn)
            return
        }
        val replyText = try {
            client.chat(
                model = model.modelID,
                apiKey = apiKey,
                messages = providerMessages.toList(),
                effort = null,
            )
        } catch (e: Throwable) {
            applyFailure(e.message ?: e.javaClass.simpleName, isFirstTurn = isFirstTurn)
            return
        }
        val cleanText = replyText.trim()
        if (cleanText.isEmpty()) {
            applyFailure("Empty response from model.", isFirstTurn = isFirstTurn)
            return
        }
        providerMessages += ProviderChatMessage(
            role = ProviderChatMessage.Role.ASSISTANT,
            content = cleanText,
        )
        val current = _state.value
        _state.value = current.copy(
            phase = Phase.Result,
            analysisText = if (isFirstTurn) cleanText else current.analysisText,
            turns = if (isFirstTurn) {
                listOf(Turn(Turn.Role.Assistant, cleanText))
            } else {
                current.turns + Turn(Turn.Role.Assistant, cleanText)
            },
            isAnalyzing = false,
            isReplying = false,
            errorMessage = null,
        )
    }

    private fun applyFailure(message: String, isFirstTurn: Boolean) {
        val current = _state.value
        _state.value = current.copy(
            phase = if (current.imageBytes != null) Phase.Failed else Phase.Live,
            isAnalyzing = false,
            isReplying = false,
            errorMessage = message,
            // For first-turn failures, surface the error in the empty
            // analysis slot so the user can see it next to the image.
            analysisText = if (isFirstTurn && current.imageBytes != null) "" else current.analysisText,
            turns = if (isFirstTurn) {
                if (current.imageBytes != null) listOf(Turn(Turn.Role.Assistant, message, isError = true)) else emptyList()
            } else {
                current.turns + Turn(Turn.Role.Assistant, message, isError = true)
            },
        )
    }

    /** Read the live model list (when the user has a key) and prepend defaults. */
    private suspend fun loadLiveVisionModels(
        current: ProviderId,
        apiKey: String?,
    ): List<AIModel> {
        val all = if (apiKey.isNullOrEmpty()) {
            ModelCatalog.defaults
        } else {
            val results = ModelCatalog.fetchAll(
                keys = mapOf(current to apiKey),
                http = container.httpClient,
            ).firstOrNull()
            val live = results?.models.orEmpty()
            (live + ModelCatalog.defaults).distinctBy { "${it.provider.rawValue}/${it.modelID}" }
        }
        return all.filter { ModelCapabilities.supportsVision(it) }
            .sortedBy { it.displayName.lowercase() }
    }

    companion object {
        /**
         * Built-in fallback prompt for the first analysis pass. We don't
         * tell the model to format a quiz answer etc. (iOS does) — the
         * Android MVP keeps it general; users can add the same prompt
         * library in a follow-up.
         */
        private const val DEFAULT_PROMPT: String =
            "Analyze this photo for the user. Start with the key takeaway or " +
                "identification in 1–3 short sentences, then add brief " +
                "supporting details: notable objects, readable text, " +
                "layout, or anything useful. Be concise."

        private const val MISSING_KEY_HINT: String =
            "Add an API key for a vision-capable provider in Settings to get started."

        /** Base64-encode image bytes into the wire attachment shape. */
        fun toAttachment(bytes: ByteArray, mime: String): ProviderChatMessage.ImageAttachment =
            ProviderChatMessage.ImageAttachment(
                mimeType = mime,
                base64Data = Base64.encodeToString(bytes, Base64.NO_WRAP),
            )

        /** Read a content URI into bytes — used by the gallery launcher. */
        suspend fun readBytes(resolver: ContentResolver, uri: Uri): ByteArray? =
            withContext(Dispatchers.IO) {
                runCatching { resolver.openInputStream(uri)?.use { it.readBytes() } }
                    .getOrNull()
            }

        /**
         * Factory wired by [Composable] callers; pulls the [AppContainer]
         * out of the [Application]. We can't use [AndroidViewModel] here
         * directly because we need to read the [AppContainer], not just
         * the [Application], and the container is initialised in
         * `RoamSocketApplication.onCreate`.
         */
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY] as RoamSocketApplication
                VisionViewModel(app.container)
            }
        }
    }
}
