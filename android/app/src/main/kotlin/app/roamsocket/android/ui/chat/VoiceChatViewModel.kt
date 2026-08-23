package app.roamsocket.android.ui.chat

import android.app.Application
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.Locale

/**
 * PR #77: voice chat view-model. Mirrors the iOS
 * `ios/.../VoiceChatViewModel` flow at a smaller scope:
 *
 *  * `idle`     — waiting for the user to tap the mic.
 *  * `listening` — `SpeechRecognizer` is open; [liveCaption] shows the
 *    partial transcript in real time.
 *  * `thinking`  — the partial transcript was committed; we asked the
 *    chat view-model to send it as a message and are waiting for the
 *    assistant to finish.
 *  * `speaking`  — the assistant's reply is being read aloud via
 *    `TextToSpeech`. We loop back to `listening` after the reply ends
 *    so the user can keep the conversation going hands-free.
 *  * `error(String)` — surface a transient failure to the UI; the user
 *    can retry by tapping the mic again.
 *
 * Stays close to the iOS `Phase` enum so the Compose UI can render
 * the same status headline in the same order. Differences from iOS:
 *
 *  * No `VoiceSettingsStore` port — Android ships one default voice
 *    per `TextToSpeech` engine. iOS-specific voice selection is left
 *    as a follow-up.
 *  * No personal-voice / HiFi GAN support — that's Apple-only.
 *
 * The actual `ChatViewModel.send(...)` call is made on the
 * [androidx.lifecycle.viewModelScope] via [pendingSendCallback] so the
 * UI layer can wire the right [ChatViewModel] (which is itself
 * constructed per-chat-id and has its own factory).
 */
class VoiceChatViewModel(
    application: Application,
) : AndroidViewModel(application) {

    enum class Phase {
        IDLE,
        LISTENING,
        THINKING,
        SPEAKING,
        ERROR,
    }

    private val _state = MutableStateFlow(VoiceChatUiState())
    val state: StateFlow<VoiceChatUiState> = _state.asStateFlow()

    private var speechRecognizer: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false

    /**
     * Callback the host wires in to route a committed turn through the
     * active `ChatViewModel.send(...)`. The voice layer doesn't know
     * which chat is "active" — the chat screen is what decides that.
     */
    var pendingSendCallback: ((String) -> Unit)? = null
    /**
     * Callback fired with the assistant's reply so the voice layer
     * can read it aloud. Same indirection — the chat screen owns the
     * model state.
     */
    var replyReadyCallback: ((String) -> Unit)? = null

    init {
        tts = TextToSpeech(application) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (!ttsReady) {
                _state.value = _state.value.copy(
                    phase = Phase.ERROR,
                    statusHeadline = "Text-to-speech engine unavailable.",
                )
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        speechRecognizer?.destroy()
        speechRecognizer = null
        tts?.stop()
        tts?.shutdown()
        tts = null
    }

    /**
     * Begin a listening turn. Creates a `SpeechRecognizer` on first
     * call; `RecognitionListener` callbacks feed `liveCaption` and
     * the `Phase` machine.
     */
    fun startListening() {
        val context = getApplication<Application>()
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            _state.value = _state.value.copy(
                phase = Phase.ERROR,
                statusHeadline = "Speech recognition isn't available on this device.",
            )
            return
        }
        if (speechRecognizer == null) {
            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(context).also {
                it.setRecognitionListener(VoiceRecognitionListener(this))
            }
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
        _state.value = _state.value.copy(
            phase = Phase.LISTENING,
            liveCaption = "",
            statusHeadline = "Listening…",
        )
        speechRecognizer?.startListening(intent)
    }

    fun stopListening() {
        speechRecognizer?.stopListening()
    }

    /**
     * Commit the current caption as a chat turn. The host's
     * `pendingSendCallback` (wired in `VoiceChatScreen`) is what
     * actually drives `ChatViewModel.send(...)`. We then flip into
     * `THINKING` and wait for the assistant's reply via
     * [onAssistantReply].
     */
    fun commitTurn() {
        val caption = _state.value.liveCaption.trim()
        if (caption.isEmpty()) {
            _state.value = _state.value.copy(phase = Phase.IDLE)
            return
        }
        _state.value = _state.value.copy(
            phase = Phase.THINKING,
            statusHeadline = "Thinking…",
        )
        pendingSendCallback?.invoke(caption)
    }

    /**
     * Called by the host once the assistant finishes the turn.
     * Speaks the reply aloud and loops back to listening so the
     * user can keep the conversation going.
     */
    fun onAssistantReply(reply: String) {
        val cleaned = reply.trim()
        if (cleaned.isEmpty()) {
            _state.value = _state.value.copy(phase = Phase.IDLE)
            return
        }
        _state.value = _state.value.copy(
            phase = Phase.SPEAKING,
            liveCaption = cleaned,
            statusHeadline = cleaned,
        )
        if (!ttsReady) {
            // Without a TTS engine just fall back to IDLE so the user
            // can tap the mic again.
            _state.value = _state.value.copy(phase = Phase.IDLE)
            return
        }
        tts?.setOnUtteranceProgressListener(object : android.speech.tts.UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) = Unit
            override fun onDone(utteranceId: String?) {
                // Hop back to listening on the main thread so the user
                // can keep the conversation going.
                viewModelScope.launch {
                    _state.value = _state.value.copy(
                        phase = Phase.IDLE,
                        statusHeadline = "Tap the mic to keep going.",
                    )
                }
            }

            @Deprecated("Required by API but never called in practice")
            override fun onError(utteranceId: String?) {
                viewModelScope.launch {
                    _state.value = _state.value.copy(
                        phase = Phase.IDLE,
                        statusHeadline = "Tap the mic to keep going.",
                    )
                }
            }
        })
        tts?.speak(cleaned, TextToSpeech.QUEUE_FLUSH, Bundle(), "voice-chat-reply")
    }

    /**
     * Switch into a transient error state. The status headline carries
     * the human-readable reason; the UI surfaces it under the
     * transcript until the user retries.
     */
    fun presentError(message: String) {
        _state.value = _state.value.copy(
            phase = Phase.ERROR,
            statusHeadline = message,
        )
    }

    fun resetToIdle() {
        _state.value = _state.value.copy(phase = Phase.IDLE, statusHeadline = "Start chatting anytime")
    }

    // ---- internal callbacks driven by the recognition listener ----

    internal fun onPartialResult(text: String) {
        _state.value = _state.value.copy(liveCaption = text)
    }

    internal fun onFinalResult(text: String) {
        _state.value = _state.value.copy(
            liveCaption = text,
            phase = Phase.IDLE,
        )
    }

    internal fun onRecognitionError(code: Int) {
        _state.value = _state.value.copy(
            phase = Phase.ERROR,
            statusHeadline = humanReadableRecognitionError(code),
        )
    }

    private fun humanReadableRecognitionError(code: Int): String = when (code) {
        SpeechRecognizer.ERROR_AUDIO -> "Couldn't capture audio. Check your microphone."
        SpeechRecognizer.ERROR_CLIENT -> "Voice chat stopped unexpectedly."
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission was denied."
        SpeechRecognizer.ERROR_NETWORK -> "Couldn't reach the speech service. Check your connection."
        SpeechRecognizer.ERROR_NO_MATCH -> "I didn't catch that. Tap the mic and try again."
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "I stopped hearing you. Tap the mic to retry."
        else -> "Voice chat is unavailable right now."
    }
}

data class VoiceChatUiState(
    val phase: VoiceChatViewModel.Phase = VoiceChatViewModel.Phase.IDLE,
    val liveCaption: String = "",
    val statusHeadline: String = "Start chatting anytime",
)

/**
 * `RecognitionListener` that pipes `SpeechRecognizer` callbacks into
 * the voice view-model. Kept private so the rest of the app deals
 * only with [VoiceChatViewModel].
 */
private class VoiceRecognitionListener(
    private val viewModel: VoiceChatViewModel,
) : RecognitionListener {
    override fun onReadyForSpeech(params: Bundle?) = Unit
    override fun onBeginningOfSpeech() = Unit
    override fun onRmsChanged(rmsdB: Float) = Unit
    override fun onBufferReceived(buffer: ByteArray?) = Unit
    override fun onEndOfSpeech() = Unit
    override fun onEvent(eventType: Int, params: Bundle?) = Unit

    override fun onPartialResults(partialResults: Bundle?) {
        val text = partialResults
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            .orEmpty()
        if (text.isNotEmpty()) viewModel.onPartialResult(text)
    }

    override fun onResults(results: Bundle?) {
        val text = results
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            .orEmpty()
        viewModel.onFinalResult(text)
    }

    override fun onError(error: Int) {
        viewModel.onRecognitionError(error)
    }
}
