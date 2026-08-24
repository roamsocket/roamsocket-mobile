package app.roamsocket.android.ui.study

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * A single saved flashcard (question + answer + reasoning).
 *
 * Ports [Flashcard] from iOS `FlashcardModels.swift`.
 */
data class Flashcard(
    val id: String = UUID.randomUUID().toString(),
    var question: String = "",
    var answer: String = "",
    var reasoning: String = "",
    val createdAt: Long = System.currentTimeMillis(),
    var updatedAt: Long = System.currentTimeMillis(),
)

/**
 * A deck of flashcards. One Study scan session saves every scanned page
 * into a single deck.
 *
 * Ports [FlashcardDeck] from iOS `FlashcardModels.swift`.
 */
data class FlashcardDeck(
    val id: String = UUID.randomUUID().toString(),
    var title: String = "",
    val createdAt: Long = System.currentTimeMillis(),
    var updatedAt: Long = System.currentTimeMillis(),
    val cards: MutableList<Flashcard> = mutableListOf(),
) {
    /** Cards in scan order (oldest first). */
    val sortedCards: List<Flashcard>
        get() = cards.sortedBy { it.createdAt }
}

/** JSON serialisation keys. */
private const val KEY_ID = "id"
private const val KEY_TITLE = "title"
private const val KEY_CREATED_AT = "createdAt"
private const val KEY_UPDATED_AT = "updatedAt"
private const val KEY_CARDS = "cards"

/** Persists flashcard decks in SharedPreferences (local-only, like Artifacts).
 *
 *  Ports [FlashcardDeckStore] from iOS `FlashcardModels.swift`.
 */
class FlashcardDeckStore(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("flashcardDecks.v1", Context.MODE_PRIVATE)

    private val _decks = MutableStateFlow<List<FlashcardDeck>>(emptyList())
    val decks: StateFlow<List<FlashcardDeck>> = _decks.asStateFlow()

    init { load() }

    /** Decks newest-activity first. */
    val sortedDecks: List<FlashcardDeck>
        get() = _decks.value.sortedByDescending { it.updatedAt }

    fun deckById(id: String): FlashcardDeck? =
        _decks.value.firstOrNull { it.id == id }

    /** Insert or replace a deck by id. Touches `updatedAt` so it bubbles to
     *  the top of the list when cards are added or edited. */
    fun upsertDeck(deck: FlashcardDeck): FlashcardDeck {
        val updated = deck.copy(updatedAt = System.currentTimeMillis())
        val current = _decks.value.toMutableList()
        val idx = current.indexOfFirst { it.id == deck.id }
        if (idx >= 0) {
            current[idx] = updated
        } else {
            current.add(0, updated)
        }
        _decks.value = current
        save()
        return updated
    }

    fun renameDeck(id: String, title: String) {
        val current = _decks.value.toMutableList()
        val idx = current.indexOfFirst { it.id == id }
        if (idx < 0) return
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        current[idx] = current[idx].copy(
            title = trimmed,
            updatedAt = System.currentTimeMillis(),
        )
        _decks.value = current
        save()
    }

    fun deleteDeck(id: String) {
        _decks.value = _decks.value.filter { it.id != id }
        save()
    }

    fun clearAll() {
        _decks.value = emptyList()
        save()
    }

    // ---------------------------------------------------------------------
    // JSON serialisation
    // ---------------------------------------------------------------------

    private fun save() {
        val json = JSONArray()
        for (deck in _decks.value) {
            json.put(deck.toJson())
        }
        prefs.edit { putString(KEY_CARDS, json.toString()) }
    }

    private fun load() {
        val raw = prefs.getString(KEY_CARDS, null) ?: return
        try {
            val array = JSONArray(raw)
            val list = mutableListOf<FlashcardDeck>()
            for (i in 0 until array.length()) {
                parseDeck(array.getJSONObject(i))?.let { list.add(it) }
            }
            _decks.value = list
        } catch (_: Throwable) {
            // Corrupt storage — start fresh.
            _decks.value = emptyList()
        }
    }

    private fun FlashcardDeck.toJson(): JSONObject =
        JSONObject().apply {
            put(KEY_ID, id)
            put(KEY_TITLE, title)
            put(KEY_CREATED_AT, createdAt)
            put(KEY_UPDATED_AT, updatedAt)
            val cardsArray = JSONArray()
            for (card in cards) {
                cardsArray.put(card.toJson())
            }
            put(KEY_CARDS, cardsArray)
        }

    private fun Flashcard.toJson(): JSONObject =
        JSONObject().apply {
            put(KEY_ID, id)
            put("question", question)
            put("answer", answer)
            put("reasoning", reasoning)
            put(KEY_CREATED_AT, createdAt)
            put(KEY_UPDATED_AT, updatedAt)
        }

    private fun parseDeck(obj: JSONObject): FlashcardDeck? = try {
        val cardsArray = obj.optJSONArray(KEY_CARDS) ?: JSONArray()
        val cards = mutableListOf<Flashcard>()
        for (i in 0 until cardsArray.length()) {
            parseCard(cardsArray.getJSONObject(i))?.let { cards.add(it) }
        }
        FlashcardDeck(
            id = obj.getString(KEY_ID),
            title = obj.optString(KEY_TITLE, ""),
            createdAt = obj.optLong(KEY_CREATED_AT, System.currentTimeMillis()),
            updatedAt = obj.optLong(KEY_UPDATED_AT, System.currentTimeMillis()),
            cards = cards,
        )
    } catch (_: Throwable) {
        null
    }

    private fun parseCard(obj: JSONObject): Flashcard? = try {
        Flashcard(
            id = obj.getString(KEY_ID),
            question = obj.optString("question", ""),
            answer = obj.optString("answer", ""),
            reasoning = obj.optString("reasoning", ""),
            createdAt = obj.optLong(KEY_CREATED_AT, System.currentTimeMillis()),
            updatedAt = obj.optLong(KEY_UPDATED_AT, System.currentTimeMillis()),
        )
    } catch (_: Throwable) {
        null
    }
}
