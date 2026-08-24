package app.roamsocket.android.ui.study

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Drives the Study scan flow: camera → vision analysis → editable flashcards
 * → save into the session deck.
 *
 * Ports [StudyViewModel] from iOS `StudyViewModel.swift`.
 */
class StudyViewModel(
    private val container: AppContainer,
    private val deckStore: FlashcardDeckStore,
) : ViewModel() {

    enum class Phase {
        LIVE, CAPTURING, ANALYZING, REVIEW, FAILED,
    }

    data class UiState(
        val phase: Phase = Phase.LIVE,
        val capturedImage: Bitmap? = null,
        val cards: List<StudyFlashcardDraft> = emptyList(),
        val selectedModel: AIModel? = null,
        val visionModels: List<AIModel> = emptyList(),
        val isThinking: Boolean = false,
        val errorMessage: String? = null,
    ) {
        val savedCount: Int get() = cards.count { it.isSaved }
        val unsavedCount: Int get() = cards.count { !it.isSaved }
        val hasUnsavedCards: Boolean get() = cards.any { !it.isSaved }
        val canSaveAll: Boolean get() = hasUnsavedCards && !isThinking
        val isFailed: Boolean get() = phase == Phase.FAILED
    }

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    /** Deck this scan session saves into. Created on the first capture and
     *  persisted to the store on the first card save. */
    private var sessionDeck: FlashcardDeck? = null

    private var analysisJob: Job? = null

    init {
        viewModelScope.launch {
            loadVisionModels()
        }
    }

    /** User picked a model from the picker sheet. */
    fun selectModel(model: AIModel) {
        _state.value = _state.value.copy(selectedModel = model)
        viewModelScope.launch {
            container.userSettings.setCurrent(model.provider, model.modelID)
        }
    }

    /** Shutter fired — freeze the preview and open the analyzing state before
     *  the still finishes developing. */
    fun beginCapture() {
        if (!canCapture) return
        analysisJob?.cancel()
        analysisJob = null

        _state.value = _state.value.copy(
            phase = Phase.CAPTURING,
            capturedImage = null,
            cards = emptyList(),
            errorMessage = null,
            isThinking = false,
        )
    }

    /** Process the captured still with the selected vision model. */
    fun analyze(image: Bitmap) {
        val current = _state.value
        if (current.phase != Phase.CAPTURING && current.phase != Phase.ANALYZING) return
        analysisJob?.cancel()
        _state.value = current.copy(
            phase = Phase.ANALYZING,
            capturedImage = image,
            cards = emptyList(),
            errorMessage = null,
            isThinking = true,
        )
        runAnalysisTask(image)
    }

    /** Same image, same model — useful after picking a new vision model. */
    fun retryAnalysis() {
        val image = _state.value.capturedImage ?: return
        if (_state.value.phase != Phase.FAILED) return
        analysisJob?.cancel()
        _state.value = _state.value.copy(
            phase = Phase.ANALYZING,
            cards = emptyList(),
            errorMessage = null,
            isThinking = true,
        )
        runAnalysisTask(image)
    }

    /** Back to the live camera for the next page. */
    fun startNextScan() {
        analysisJob?.cancel()
        analysisJob = null
        sessionDeck = null
        _state.value = UiState(phase = Phase.LIVE, visionModels = _state.value.visionModels)
        viewModelScope.launch { loadVisionModels() }
    }

    /** User edited a card field. */
    fun cardEdited(id: String) {
        val cards = _state.value.cards.toMutableList()
        val idx = cards.indexOfFirst { it.id == id }
        if (idx < 0) return
        if (!cards[idx].isDirty) {
            cards[idx] = cards[idx].copy(isDirty = true)
            _state.value = _state.value.copy(cards = cards)
        }
    }

    /** Write one card into the session deck. */
    fun saveCard(id: String) {
        val cards = _state.value.cards.toMutableList()
        val idx = cards.indexOfFirst { it.id == id }
        if (idx < 0) return
        val flashcard = cards[idx].toFlashcard()
        val deck = deckByUpserting(flashcard)
        sessionDeck = deck
        cards[idx] = cards[idx].copy(isSaved = true, isDirty = false)
        _state.value = _state.value.copy(cards = cards)
    }

    /** Save every unsaved card. */
    fun saveAllCards() {
        for (card in _state.value.cards.filter { !it.isSaved }) {
            saveCard(card.id)
        }
    }

    fun dismissError() {
        _state.value = _state.value.copy(errorMessage = null)
    }

    // ---------------------------------------------------------------------
    // Computed state helpers
    // ---------------------------------------------------------------------

    private val canCapture: Boolean
        get() = _state.value.phase != Phase.CAPTURING &&
                _state.value.phase != Phase.ANALYZING &&
                _state.value.selectedModel != null

    // ---------------------------------------------------------------------
    // Analysis
    // ---------------------------------------------------------------------

    private fun runAnalysisTask(image: Bitmap) {
        analysisJob = viewModelScope.launch {
            try {
                val forDisplay = scaleForDisplay(image)
                val jpegBytes = jpegData(image)
                val attachment = toAttachment(jpegBytes)
                val messages = listOf(
                    ProviderChatMessage(
                        role = ProviderChatMessage.Role.USER,
                        content = studyAnalysisPrompt,
                        images = listOf(attachment),
                    ),
                )
                val reply = runChat(messages)
                val parsed = StudyQuestionParser.parse(reply)
                _state.value = _state.value.copy(
                    phase = Phase.REVIEW,
                    capturedImage = forDisplay,
                    cards = parsed.map {
                        StudyFlashcardDraft(question = it.question, answer = it.answer, reasoning = it.reasoning)
                    },
                    isThinking = false,
                )
            } catch (e: Throwable) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                _state.value = _state.value.copy(
                    phase = Phase.FAILED,
                    errorMessage = e.message ?: e.javaClass.simpleName,
                    isThinking = false,
                )
            }
        }
    }

    private suspend fun runChat(messages: List<ProviderChatMessage>): String {
        val model = _state.value.selectedModel
            ?: throw IllegalStateException("No vision model selected.")
        val apiKey = container.secretStore.readApiKey(model.provider).orEmpty()
        if (model.provider.requiresApiKey && apiKey.isEmpty()) {
            throw IllegalStateException("No API key for ${model.provider.displayName}. Add one in Settings.")
        }
        val client = ProviderRegistry.client(model.provider, container.httpClient)
            ?: throw IllegalStateException("No client registered for ${model.provider.displayName}.")
        return client.chat(
            model = model.modelID,
            apiKey = apiKey,
            messages = messages,
            effort = null,
        )
    }

    // ---------------------------------------------------------------------
    // Deck management
    // ---------------------------------------------------------------------

    private fun deckByUpserting(flashcard: Flashcard): FlashcardDeck {
        val deck = ensureSessionDeck()
        val updated = if (deck.cards.any { it.id == flashcard.id }) {
            deck.copy(
                cards = deck.cards.map { if (it.id == flashcard.id) flashcard else it }.toMutableList(),
            )
        } else {
            deck.copy(cards = (deck.cards + flashcard).toMutableList())
        }
        // Name the deck from the first real question so multiple decks on the
        // same day stay distinguishable.
        if (updated.cards.size == 1 && flashcard.question.isNotEmpty()) {
            return deckStore.upsertDeck(updated.copy(title = deriveDeckTitle(flashcard.question)))
        }
        return deckStore.upsertDeck(updated)
    }

    private fun ensureSessionDeck(): FlashcardDeck {
        if (sessionDeck != null) return sessionDeck!!
        val deck = FlashcardDeck(title = defaultDeckTitle())
        sessionDeck = deck
        return deck
    }

    // ---------------------------------------------------------------------
    // Vision model loading
    // ---------------------------------------------------------------------

    private suspend fun loadVisionModels() {
        val provider = container.userSettings.currentProvider.first()
        val modelID = container.userSettings.currentModel.first()
        val apiKey = container.secretStore.readApiKey(provider)
        val all = if (apiKey.isNullOrEmpty()) {
            ModelCatalog.defaults
        } else {
            val results = ModelCatalog.fetchAll(
                keys = mapOf(provider to apiKey),
                http = container.httpClient,
            ).firstOrNull()
            val live = results?.models.orEmpty()
            (live + ModelCatalog.defaults).distinctBy { "${it.provider.rawValue}/${it.modelID}" }
        }
        val visionModels = all.filter { ModelCapabilities.supportsVision(it) }
            .sortedBy { it.displayName.lowercase() }
        val selected = visionModels.firstOrNull { it.provider == provider }
            ?: visionModels.firstOrNull()
        _state.value = _state.value.copy(
            selectedModel = selected,
            visionModels = visionModels,
        )
    }

    // ---------------------------------------------------------------------
    // Static helpers
    // ---------------------------------------------------------------------

    private val studyAnalysisPrompt: String = """
You are a study assistant. Look at this photo. It contains questions — a quiz, test, worksheet, homework page, or flashcard set.

Extract every question together with its correct answer and a short reasoning.

Output exactly one block per question in this format, with blocks separated by a line containing only ---:

QUESTION: <the full question, including the options if it is multiple choice>
ANSWER: <the correct answer: True/False, a letter, a number, or a short phrase>
REASON: <one or two concise sentences explaining why that is the correct answer>

Rules:
- Copy each question text as closely as you can.
- If a question has no visible answer, still give your best answer and note the uncertainty in REASON.
- If the photo does not contain any questions, reply with exactly: NO_QUESTIONS
- Do not add an intro, outro, numbering, headers, or any other text outside the blocks.
    """.trimIndent()

    private fun defaultDeckTitle(): String {
        val formatter = SimpleDateFormat("MMM d", Locale.US)
        return "Study \u00b7 ${formatter.format(Date())}"
    }

    private fun deriveDeckTitle(question: String): String {
        val clean = question.trim().replace("\n", " ")
        if (clean.isEmpty()) return defaultDeckTitle()
        return if (clean.length <= 42) clean else clean.take(42).trimEnd() + "\u2026"
    }

    /** Scale bitmap to a display-safe size without keeping a 12MP buffer around. */
    private fun scaleForDisplay(image: Bitmap, maxDim: Int = 1440): Bitmap {
        val longest = maxOf(image.width, image.height)
        if (longest <= maxDim) return image
        val scale = maxDim.toFloat() / longest
        return Bitmap.createScaledBitmap(
            image,
            (image.width * scale).toInt(),
            (image.height * scale).toInt(),
            true,
        )
    }

    /** Encode bitmap as JPEG bytes, scaled for wire transport. */
    private fun jpegData(image: Bitmap, maxDim: Int = 1600, quality: Int = 72): ByteArray {
        val scaled = scaleForDisplay(image, maxDim)
        val baos = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, quality, baos)
        return baos.toByteArray()
    }

    /** Base64-encode JPEG bytes into the wire attachment shape. */
    private fun toAttachment(bytes: ByteArray): ProviderChatMessage.ImageAttachment =
        ProviderChatMessage.ImageAttachment(
            mimeType = "image/jpeg",
            base64Data = Base64.encodeToString(bytes, Base64.NO_WRAP),
        )

    /** Read a content URI into a Bitmap. */
    suspend fun readBitmap(context: Context, uri: Uri): Bitmap? =
        withContext(Dispatchers.IO) {
            try {
                context.contentResolver.openInputStream(uri)?.use { stream ->
                    BitmapFactory.decodeStream(stream)
                }
            } catch (_: Throwable) {
                null
            }
        }

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY] as RoamSocketApplication
                StudyViewModel(app.container, FlashcardDeckStore(app))
            }
        }
    }
}
