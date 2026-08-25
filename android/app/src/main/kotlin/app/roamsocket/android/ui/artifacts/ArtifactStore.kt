package app.roamsocket.android.ui.artifacts

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
 * Local-only persistence for saved chat artifacts. Stores a JSON blob in
 * SharedPreferences (the same `artifacts.v1` key the iOS app uses) so
 * cross-platform storage stays in sync if we ever add a sync layer.
 *
 * Ports `ArtifactStore` from
 * `ios/AnyProvCore/Sources/AnyProvCore/Artifacts/ArtifactStore.swift`.
 */
class ArtifactStore(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("artifacts.v1", Context.MODE_PRIVATE)

    private val _artifacts = MutableStateFlow<List<Artifact>>(emptyList())
    val artifacts: StateFlow<List<Artifact>> = _artifacts.asStateFlow()

    init { load() }

    /** Newest-first. */
    val sortedArtifacts: List<Artifact>
        get() = _artifacts.value.sortedByDescending { it.createdAt }

    fun artifactById(id: String): Artifact? =
        _artifacts.value.firstOrNull { it.id == id }

    /**
     * Save the [content] if it meets the artifact threshold
     * (≥ [ARTIFACT_MIN_LINES] lines OR contains a code block). Idempotent
     * for the same `chatId + messageId` and dedupes against an existing
     * identical-content artifact in the same chat.
     */
    fun maybeSave(
        chatId: String?,
        messageId: String? = null,
        content: String,
        title: String? = null,
    ): Artifact? {
        val lines = content.split('\n').size
        val containsCodeBlock = content.contains("```")
        if (lines < ARTIFACT_MIN_LINES && !containsCodeBlock) return null
        return upsert(
            chatId = chatId,
            messageId = messageId,
            content = content,
            title = title,
            lineCount = lines,
        )
    }

    /**
     * Always save non-empty content (used for the user-initiated
     * "Save as artifact" affordance). Skips empty input.
     */
    fun save(
        chatId: String? = null,
        messageId: String? = null,
        content: String,
        title: String? = null,
    ): Artifact? {
        if (content.isBlank()) return null
        val lines = content.split('\n').size
        return upsert(
            chatId = chatId,
            messageId = messageId,
            content = content,
            title = title,
            lineCount = maxOf(1, lines),
        )
    }

    /** Update the display title (e.g. after a smarter rename). */
    fun updateTitle(id: String, title: String): Artifact? {
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return null
        val current = _artifacts.value.toMutableList()
        val idx = current.indexOfFirst { it.id == id }
        if (idx < 0) return null
        current[idx] = current[idx].copy(title = trimmed)
        _artifacts.value = current
        save()
        return current[idx]
    }

    fun delete(id: String) {
        _artifacts.value = _artifacts.value.filter { it.id != id }
        save()
    }

    fun clearAll() {
        _artifacts.value = emptyList()
        save()
    }

    // ------------------------------------------------------------------
    // Upsert / persistence
    // ------------------------------------------------------------------

    private fun upsert(
        chatId: String?,
        messageId: String?,
        content: String,
        title: String?,
        lineCount: Int,
    ): Artifact? {
        val resolvedTitle = title?.trim()?.takeIf { it.isNotEmpty() }
            ?: deriveTitle(content)

        val current = _artifacts.value.toMutableList()

        // Same assistant message → update in place.
        if (messageId != null) {
            val idx = current.indexOfFirst { it.messageId == messageId }
            if (idx >= 0) {
                val existing = current[idx]
                current[idx] = existing.copy(
                    content = content,
                    // Keep an explicit title if the caller passed one;
                    // otherwise re-derive if we only have the placeholder.
                    title = if (title != null && title.isNotBlank()) resolvedTitle
                        else if (existing.title == "Artifact" || existing.title.isBlank()) resolvedTitle
                        else existing.title,
                    lineCount = lineCount,
                )
                _artifacts.value = current
                save()
                return current[idx]
            }
        }

        // De-dupe identical content in the same chat.
        if (chatId != null) {
            val dup = current.firstOrNull { it.chatId == chatId && it.content == content }
            if (dup != null) return dup
        }

        val artifact = Artifact(
            id = UUID.randomUUID().toString(),
            createdAt = System.currentTimeMillis(),
            chatId = chatId,
            messageId = messageId,
            title = resolvedTitle,
            content = content,
            lineCount = lineCount,
        )
        current.add(0, artifact)
        _artifacts.value = current
        save()
        return artifact
    }

    private fun save() {
        val json = JSONArray()
        for (artifact in _artifacts.value) {
            json.put(artifact.toJson())
        }
        prefs.edit { putString(KEY_ARTIFACTS, json.toString()) }
    }

    private fun load() {
        val raw = prefs.getString(KEY_ARTIFACTS, null) ?: return
        try {
            val array = JSONArray(raw)
            val list = mutableListOf<Artifact>()
            for (i in 0 until array.length()) {
                parseArtifact(array.getJSONObject(i))?.let { list.add(it) }
            }
            _artifacts.value = list
        } catch (_: Throwable) {
            // Corrupt storage — start fresh.
            _artifacts.value = emptyList()
        }
    }

    private fun Artifact.toJson(): JSONObject =
        JSONObject().apply {
            put(KEY_ID, id)
            put(KEY_CREATED_AT, createdAt)
            put(KEY_CHAT_ID, chatId)
            put(KEY_MESSAGE_ID, messageId)
            put(KEY_TITLE, title)
            put(KEY_CONTENT, content)
            put(KEY_LINE_COUNT, lineCount)
        }

    private fun parseArtifact(obj: JSONObject): Artifact? = try {
        Artifact(
            id = obj.getString(KEY_ID),
            createdAt = obj.optLong(KEY_CREATED_AT, System.currentTimeMillis()),
            chatId = obj.optString(KEY_CHAT_ID, "").takeIf { it.isNotEmpty() },
            messageId = obj.optString(KEY_MESSAGE_ID, "").takeIf { it.isNotEmpty() },
            title = obj.optString(KEY_TITLE, "Artifact"),
            content = obj.optString(KEY_CONTENT, ""),
            lineCount = obj.optInt(KEY_LINE_COUNT, 1),
        )
    } catch (_: Throwable) {
        null
    }

    /** First non-empty line of [content], used as a default title. */
    private fun deriveTitle(content: String): String {
        for (raw in content.split('\n')) {
            var line = raw.trim()
            if (line.startsWith("```")) continue
            if (line.startsWith("#")) {
                line = line.dropWhile { it == '#' }.trim()
            }
            if (line.isNotEmpty()) return line.take(80)
        }
        return "Artifact"
    }

    private companion object {
        const val KEY_ARTIFACTS = "artifacts"
        const val KEY_ID = "id"
        const val KEY_CREATED_AT = "createdAt"
        const val KEY_CHAT_ID = "chatId"
        const val KEY_MESSAGE_ID = "messageId"
        const val KEY_TITLE = "title"
        const val KEY_CONTENT = "content"
        const val KEY_LINE_COUNT = "lineCount"
    }
}
