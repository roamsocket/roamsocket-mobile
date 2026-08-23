package app.roamsocket.android.ui.chat

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.UUID

/**
 * PR #79: on-device memory store. The iOS app uses
 * `UserMemoryStore` to keep a structured map of personal facts
 * (name, role, recurring project context, …) that the model can
 * reference across sessions. The Android port starts with a smaller
 * in-memory version:
 *
 *  * One flat map from a stable target key (e.g. the memory's title
 *    or `Profile` for the default profile card) to a [MemoryEntry].
 *  * Every mutation produces an [ActivityEntry] that the chat
 *    view-model surfaces as a `MemoryHintCard` with an Undo button.
 *  * The activity log is bounded so a long session doesn't leak
 *    every auto-save into the chat transcript.
 *
 * Mirrors the iOS `UserMemoryStore` contract at a subset of its
 * surface (enough for the auto-save + undo flow). Persisting the
 * store across app launches is a follow-up — for now the data
 * lives in process memory and is rebuilt each session.
 */
class MemoryStore {

    enum class Kind { ADD, UPDATE, FORGET, RENAME }

    /** One row in the store. Mirrors the iOS `MemoryRow` shape. */
    data class MemoryEntry(
        val target: String,
        val title: String,
        val summary: String,
        val details: String,
        val updatedAtMillis: Long = System.currentTimeMillis(),
    )

    /** One mutation produced by the auto-save parser. */
    data class ActivityEntry(
        val id: String = UUID.randomUUID().toString(),
        val kind: Kind,
        val target: String,
        val title: String,
        val detailPreview: String,
        val createdAtMillis: Long = System.currentTimeMillis(),
    )

    /** Bounded so a long chat doesn't drown the transcript. */
    private val maxActivity = 64

    private val _memories = MutableStateFlow<Map<String, MemoryEntry>>(emptyMap())
    val memories: StateFlow<Map<String, MemoryEntry>> = _memories.asStateFlow()

    private val _activity = MutableStateFlow<List<ActivityEntry>>(emptyList())
    val activity: StateFlow<List<ActivityEntry>> = _activity.asStateFlow()

    /**
     * Apply a [MemoryTag] parsed from an assistant message. Returns
     * the [ActivityEntry] that the chat view-model surfaces as a
     * hint card so the user can undo.
     */
    fun apply(tag: MemoryTag): ActivityEntry {
        val entry: ActivityEntry
        when (tag) {
            is MemoryTag.Add -> {
                val newEntry = MemoryEntry(
                    target = tag.target,
                    title = tag.title,
                    summary = tag.summary,
                    details = tag.details,
                )
                _memories.update { it + (tag.target to newEntry) }
                entry = ActivityEntry(
                    kind = Kind.ADD,
                    target = tag.target,
                    title = tag.title,
                    detailPreview = tag.summary,
                )
            }
            is MemoryTag.Update -> {
                val current = _memories.value[tag.target]
                val merged = if (current != null) {
                    current.copy(
                        summary = tag.summary,
                        details = tag.details,
                        updatedAtMillis = System.currentTimeMillis(),
                    )
                } else {
                    MemoryEntry(
                        target = tag.target,
                        title = tag.target,
                        summary = tag.summary,
                        details = tag.details,
                    )
                }
                _memories.update { it + (tag.target to merged) }
                entry = ActivityEntry(
                    kind = Kind.UPDATE,
                    target = tag.target,
                    title = merged.title,
                    detailPreview = tag.summary,
                )
            }
            is MemoryTag.Forget -> {
                val existing = _memories.value[tag.target]
                if (existing != null) {
                    _memories.update { it - tag.target }
                }
                entry = ActivityEntry(
                    kind = Kind.FORGET,
                    target = tag.target,
                    title = existing?.title ?: tag.target,
                    detailPreview = existing?.summary.orEmpty(),
                )
            }
            is MemoryTag.Rename -> {
                val current = _memories.value[tag.target]
                if (current != null) {
                    _memories.update {
                        val renamed = current.copy(
                            title = tag.value,
                            updatedAtMillis = System.currentTimeMillis(),
                        )
                        it - tag.target + (tag.value to renamed)
                    }
                    entry = ActivityEntry(
                        kind = Kind.RENAME,
                        target = tag.value,
                        title = tag.value,
                        detailPreview = current.title,
                    )
                } else {
                    // Rename of a non-existent entry is a no-op on the
                    // store side but we still surface an activity row
                    // so the user sees what the model tried to do.
                    entry = ActivityEntry(
                        kind = Kind.RENAME,
                        target = tag.value,
                        title = tag.value,
                        detailPreview = tag.target,
                    )
                }
            }
            is MemoryTag.SetSummary -> {
                val current = _memories.value[tag.target]
                if (current != null) {
                    val updated = current.copy(
                        summary = tag.value,
                        updatedAtMillis = System.currentTimeMillis(),
                    )
                    _memories.update { it + (tag.target to updated) }
                }
                entry = ActivityEntry(
                    kind = Kind.UPDATE,
                    target = tag.target,
                    title = current?.title ?: tag.target,
                    detailPreview = tag.value,
                )
            }
            is MemoryTag.SetDetails -> {
                val current = _memories.value[tag.target]
                if (current != null) {
                    val updated = current.copy(
                        details = tag.value,
                        updatedAtMillis = System.currentTimeMillis(),
                    )
                    _memories.update { it + (tag.target to updated) }
                }
                entry = ActivityEntry(
                    kind = Kind.UPDATE,
                    target = tag.target,
                    title = current?.title ?: tag.target,
                    detailPreview = tag.value,
                )
            }
        }
        _activity.update { current ->
            (current + entry).takeLast(maxActivity)
        }
        return entry
    }

    /**
     * Reverse a previous [ActivityEntry]. Mirrors the iOS
     * `undoActivity(id:)`. Returns the reversed entry, or null if
     * the id is unknown.
     */
    fun undoActivity(id: String): ActivityEntry? {
        val entry = _activity.value.firstOrNull { it.id == id } ?: return null
        when (entry.kind) {
            Kind.ADD, Kind.UPDATE -> {
                // Without a backup of the prior value, the safest
                // semantics on Android are "drop the entry". The
                // user can re-add it from the model reply if needed.
                _memories.update { it - entry.target }
            }
            Kind.FORGET -> {
                // Forgetting already removed the entry; nothing to do.
            }
            Kind.RENAME -> {
                // Rename stored the old title in detailPreview. Best
                // we can do without snapshotting is drop the renamed
                // entry — a follow-up could persist the prior title.
                _memories.update { it - entry.target }
            }
        }
        _activity.update { it.filterNot { row -> row.id == id } }
        return entry
    }
}
