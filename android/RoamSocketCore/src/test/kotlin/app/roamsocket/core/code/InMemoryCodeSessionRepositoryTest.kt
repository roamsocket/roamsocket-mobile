package app.roamsocket.core.code

import app.roamsocket.core.code.CodeSession.Status.ARCHIVED
import app.roamsocket.core.code.CodeSession.Status.WORKING
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InMemoryCodeSessionRepositoryTest {

    private fun session(
        id: String,
        title: String = id,
        status: CodeSession.Status = WORKING,
        updatedAtMillis: Long = 0L,
    ) = CodeSession(
        id = id,
        title = title,
        repoFullName = "roamsocket/mobile",
        baseBranch = "main",
        workBranch = "feat/$id",
        status = status,
        createdAtMillis = updatedAtMillis,
        updatedAtMillis = updatedAtMillis,
    )

    @Test
    fun addPutsNewSessionAtTheTop() = runTest {
        val repo = InMemoryCodeSessionRepository()
        repo.add(session("a", updatedAtMillis = 1L))
        repo.add(session("b", updatedAtMillis = 2L))
        assertEquals(listOf("b", "a"), repo.active.value.map { it.id })
    }

    @Test
    fun updateMutatesTheMatchingSession() = runTest {
        val repo = InMemoryCodeSessionRepository()
        repo.add(session("a", title = "before"))
        repo.update("a") { it.copy(title = "after") }
        assertEquals("after", repo.active.value.first { it.id == "a" }.title)
    }

    @Test
    fun archiveRemovesFromActive() = runTest {
        val repo = InMemoryCodeSessionRepository()
        repo.add(session("a"))
        repo.archive("a")
        assertTrue(repo.active.value.isEmpty())
        assertEquals(1, repo.archived.value.size)
    }

    @Test
    fun deleteRemovesTheSession() = runTest {
        val repo = InMemoryCodeSessionRepository()
        repo.add(session("a"))
        repo.add(session("b"))
        repo.delete("a")
        assertEquals(listOf("b"), repo.active.value.map { it.id })
    }

    @Test
    fun snapshotIncludesArchived() = runTest {
        val repo = InMemoryCodeSessionRepository()
        repo.add(session("a"))
        repo.add(session("b"))
        repo.archive("a")
        assertEquals(setOf("a", "b"), repo.snapshot().map { it.id }.toSet())
    }

    @Test
    fun replaceAllLoadsPersistedSessions() = runTest {
        val repo = InMemoryCodeSessionRepository()
        repo.replaceAll(
            listOf(
                session("a", title = "Resumed", status = ARCHIVED, updatedAtMillis = 10L),
                session("b", updatedAtMillis = 20L),
            ),
        )
        assertEquals(1, repo.active.value.size)
        assertEquals("b", repo.active.value.first().id)
        assertEquals(1, repo.archived.value.size)
        assertEquals("a", repo.archived.value.first().id)
    }
}
