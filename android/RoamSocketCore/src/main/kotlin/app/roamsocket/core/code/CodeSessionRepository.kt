package app.roamsocket.core.code

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Persisted record of coding sessions the user has started. Mirrors the
 * surface of the iOS `CodeSessionStore`
 * (`ios/App/Sources/Features/Code/CodeHomeView.swift`).
 *
 * The Android port starts with an in-memory implementation; the app
 * module wraps it with a DataStore-backed `DataStoreCodeSessionRepository`
 * (see `app/data/`) so the list survives a cold start.
 */
public interface CodeSessionRepository {
    /**
     * All non-archived sessions, newest-updated first. Archived sessions
     * stay in the store but live in [archived].
     */
    public val active: StateFlow<List<CodeSession>>

    /** Archived sessions, newest-updated first. */
    public val archived: StateFlow<List<CodeSession>>

    /** Add a freshly-started session to the top of the list. */
    public fun add(session: CodeSession)

    /** Update fields on the session with [id]. No-op if not present. */
    public fun update(id: String, mutate: (CodeSession) -> CodeSession)

    /** Mark the session with [id] as [CodeSession.Status.ARCHIVED]. */
    public fun archive(id: String)

    /**
     * Mark archived with the iOS `disconnectWhenDone` flag — if true, the
     * desktop agent is allowed to keep running until idle; the phone
     * disconnects on next idle. Mirrors iOS `archive(_:disconnectWhenDone:)`.
     */
    public fun archive(id: String, disconnectWhenDone: Boolean)

    /** Restore an archived session to the active list. */
    public fun unarchive(id: String)

    /**
     * Toggle the per-session mid-turn flag without bumping `updatedAt`
     * (the sidebar sort uses updatedAt, so a streaming chat shouldn't
     * shuffle to the top just because it's running). Promotes status
     * to `WORKING` when active unless archived. Matches iOS
     * `setAgentActive(_:_:)`.
     */
    public fun setAgentActive(id: String, active: Boolean)

    /** Persist the latest transcript lines onto the session row. */
    public fun saveTranscript(id: String, lines: List<SessionTranscriptLine>)

    /** Rename a session (no-op if the trimmed title is empty). */
    public fun rename(id: String, title: String)

    /** Permanently remove the session. */
    public fun delete(id: String)

    /** Replace the in-memory list. Used by the DataStore loader on startup. */
    public fun replaceAll(sessions: List<CodeSession>)

    /** Snapshot of the full list (active + archived) for persistence. */
    public fun snapshot(): List<CodeSession>

    /** Look up a session by id. */
    public fun session(id: String): CodeSession? =
        snapshot().firstOrNull { it.id == id }
}

/**
 * Default in-memory implementation. Newest-first sort, archived filter
 * applied lazily in the public flows.
 */
public class InMemoryCodeSessionRepository : CodeSessionRepository {
    private val _all = MutableStateFlow<List<CodeSession>>(emptyList())
    private val _active = MutableStateFlow<List<CodeSession>>(emptyList())
    private val _archived = MutableStateFlow<List<CodeSession>>(emptyList())

    override val active: StateFlow<List<CodeSession>> = _active.asStateFlow()
    override val archived: StateFlow<List<CodeSession>> = _archived.asStateFlow()

    override fun add(session: CodeSession) {
        mutate { list -> list.add(0, session) }
    }

    override fun update(id: String, mutate: (CodeSession) -> CodeSession) {
        mutate { list ->
            val idx = list.indexOfFirst { it.id == id }
            if (idx >= 0) list[idx] = mutate(list[idx])
        }
    }

    override fun archive(id: String) {
        archive(id, disconnectWhenDone = false)
    }

    override fun archive(id: String, disconnectWhenDone: Boolean) {
        update(id) {
            it.copy(
                status = CodeSession.Status.ARCHIVED,
                disconnectWhenDone = disconnectWhenDone,
                updatedAtMillis = System.currentTimeMillis(),
            )
        }
    }

    override fun unarchive(id: String) {
        update(id) {
            it.copy(
                status = CodeSession.Status.COMPLETED,
                disconnectWhenDone = false,
                updatedAtMillis = System.currentTimeMillis(),
            )
        }
    }

    override fun setAgentActive(id: String, active: Boolean) {
        mutate { list ->
            val idx = list.indexOfFirst { it.id == id }
            if (idx < 0) return@mutate
            val current = list[idx]
            if (current.agentActive == active) return@mutate
            val promotedStatus = if (active && current.status != CodeSession.Status.ARCHIVED) {
                CodeSession.Status.WORKING
            } else {
                current.status
            }
            // Note: do NOT bump updatedAt here — a running session should
            // not shuffle to the top of the sidebar. Matches iOS
            // `setAgentActive(_:_:)`.
            list[idx] = current.copy(agentActive = active, status = promotedStatus)
        }
    }

    override fun saveTranscript(id: String, lines: List<SessionTranscriptLine>) {
        update(id) { it.copy(transcript = lines) }
    }

    override fun rename(id: String, title: String) {
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        update(id) { it.copy(title = trimmed) }
    }

    override fun delete(id: String) {
        mutate { list -> list.removeAll { it.id == id } }
    }

    override fun replaceAll(sessions: List<CodeSession>) {
        _all.value = sessions
        publish()
    }

    override fun snapshot(): List<CodeSession> = _all.value

    private inline fun mutate(block: (MutableList<CodeSession>) -> Unit) {
        val list = _all.value.toMutableList()
        block(list)
        _all.value = list
        publish()
    }

    private fun publish() {
        val now = System.currentTimeMillis()
        _active.value = _all.value
            .filter { it.status != CodeSession.Status.ARCHIVED }
            .sortedByDescending { it.updatedAtMillis }
        _archived.value = _all.value
            .filter { it.status == CodeSession.Status.ARCHIVED }
            .sortedByDescending { it.updatedAtMillis }
    }
}
