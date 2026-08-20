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

    /** Permanently remove the session. */
    public fun delete(id: String)

    /** Replace the in-memory list. Used by the DataStore loader on startup. */
    public fun replaceAll(sessions: List<CodeSession>)

    /** Snapshot of the full list (active + archived) for persistence. */
    public fun snapshot(): List<CodeSession>
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
        update(id) { it.copy(status = CodeSession.Status.ARCHIVED, updatedAtMillis = System.currentTimeMillis()) }
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
