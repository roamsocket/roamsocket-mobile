package app.roamsocket.core.projects

import app.roamsocket.core.chats.ChatHistoryItem
import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InMemoryProjectRepositoryTest {

    @Test fun createProjectInsertsAtIndexZero() = runTest {
        val repo = InMemoryProjectRepository()
        val first = repo.createProject("First")
        val second = repo.createProject("Second")
        val list = repo.projects.first()
        assertEquals(2, list.size)
        assertEquals(second.id, list[0].id)
        assertEquals(first.id, list[1].id)
        assertEquals("First", first.name)
        assertEquals("", first.instructions)
        assertEquals("", first.memory)
        assertNull(first.memoryUpdatedAtMillis)
    }

    @Test fun createProjectInitializesEmptyChatList() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        assertEquals(emptyList<ProjectChatItem>(), repo.projectChats.value[p.id])
    }

    @Test fun updateProjectInstructionsUpdatesFieldAndUpdatedAt() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        Thread.sleep(2)
        repo.updateProjectInstructions(p.id, "Think step by step.")
        val after = repo.projects.first().first { it.id == p.id }
        assertEquals("Think step by step.", after.instructions)
        assertTrue(after.updatedAtMillis > p.updatedAtMillis)
    }

    @Test fun updateProjectMemorySetsMemoryAndMemoryUpdatedAt() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        Thread.sleep(2)
        repo.updateProjectMemory(p.id, "\u2022 Likes dark mode")
        val after = repo.projects.first().first { it.id == p.id }
        assertEquals("\u2022 Likes dark mode", after.memory)
        assertNotNull(after.memoryUpdatedAtMillis)
    }

    @Test fun applyProjectMemoryCommandForgetsMatchingLine() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        repo.updateProjectMemory(p.id, "\u2022 Likes dark mode\n\n\u2022 Prefers concise replies")
        val after = repo.applyProjectMemoryCommand(p.id, "forget dark mode")
        assertEquals("\u2022 Prefers concise replies", after)
    }

    @Test fun applyProjectMemoryCommandAppendsBullet() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val after = repo.applyProjectMemoryCommand(p.id, "remember I like coffee")
        assertEquals("\u2022 I like coffee", after)
    }

    @Test fun setActiveProjectStoresId() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        repo.setActiveProject(p.id)
        assertEquals(p.id, repo.activeProjectId.first())
    }

    @Test fun setActiveProjectToUnknownIdIsNoOp() = runTest {
        val repo = InMemoryProjectRepository()
        repo.setActiveProject("does-not-exist")
        assertNull(repo.activeProjectId.first())
    }

    @Test fun setActiveProjectToNullClearsId() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        repo.setActiveProject(p.id)
        repo.setActiveProject(null)
        assertNull(repo.activeProjectId.first())
    }

    @Test fun replaceAllSeedsAllState() = runTest {
        val repo = InMemoryProjectRepository()
        val projects = listOf(
            ProjectItem(id = "p1", name = "P1", updatedAtMillis = 100L),
            ProjectItem(id = "p2", name = "P2", updatedAtMillis = 200L),
        )
        val chats = mapOf("p1" to listOf<ProjectChatItem>())
        repo.replaceAll(projects, chats, "p2")
        assertEquals(2, repo.projects.value.size)
        assertEquals("p2", repo.projects.value[0].id)
        assertEquals("p2", repo.activeProjectId.value)
    }

    @Test fun snapshotRoundTripsThroughReplaceAll() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        repo.updateProjectMemory(p.id, "hi")
        repo.setActiveProject(p.id)
        val snap = repo.snapshot()
        val fresh = InMemoryProjectRepository()
        fresh.replaceAll(snap.projects, snap.projectChats, snap.activeProjectId)
        assertEquals(snap.projects, fresh.projects.value)
        assertEquals(snap.activeProjectId, fresh.activeProjectId.value)
    }

    @Test fun pruneBlankProjectDraftsRemovesEmptyChats() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val blank = ProjectChatItem(
            id = "blank", title = "New chat", lastMessageAtMillis = 0L,
        )
        repo.replaceAll(
            projects = listOf(p),
            projectChats = mapOf(p.id to listOf(blank)),
            activeProjectId = null,
        )
        repo.pruneBlankProjectDrafts()
        assertEquals(emptyList<ProjectChatItem>(), repo.projectChats.value[p.id])
    }

    @Test fun addChatToProjectCopiesGlobalChatIntoProject() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val source = ChatHistoryItem(
            id = "c1",
            title = "SSE vs WebSockets",
            lastMessageAtMillis = 1_700_000_000_000L,
            messages = listOf(
                PersistedChatMessage(
                    id = "u1", role = PersistedChatMessage.Role.USER,
                    content = "What is SSE?", timestampMillis = 1_700_000_000_000L,
                ),
            ),
        )
        val copy = repo.addChatToProject(source, p.id)
        assertNotNull(copy)
        assertEquals(source.title, copy!!.title)
        assertEquals(1, copy.messages.size)
        assertEquals(1, repo.projectChats.value[p.id]!!.size)
        assertEquals(copy.id, repo.projectChats.value[p.id]!![0].id)
    }

    @Test fun addChatToProjectRejectsIncognito() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val incognito = ChatHistoryItem(
            id = "c1", title = "secret", lastMessageAtMillis = 0L,
            isIncognito = true,
        )
        assertNull(repo.addChatToProject(incognito, p.id))
        assertEquals(emptyList<ProjectChatItem>(), repo.projectChats.value[p.id])
    }

    @Test fun addChatToProjectOnUnknownProjectReturnsNull() = runTest {
        val repo = InMemoryProjectRepository()
        val source = ChatHistoryItem(id = "c1", title = "x", lastMessageAtMillis = 0L)
        assertNull(repo.addChatToProject(source, "missing"))
    }

    @Test fun addChatToProjectBumpsProjectUpdatedAt() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        Thread.sleep(2)
        val before = repo.projects.value.first { it.id == p.id }.updatedAtMillis
        repo.addChatToProject(
            ChatHistoryItem(id = "c1", title = "x", lastMessageAtMillis = 0L),
            p.id,
        )
        val after = repo.projects.value.first { it.id == p.id }.updatedAtMillis
        assertTrue(after > before)
    }

    @Test fun startNewChatInProjectRemovesBlankDraftAndInsertsAtTop() = runTest {
        // Matches iOS `ChatHistoryStore.startNewChat(in:)`:
        //   discardBlankProjectDrafts(in:) drops the previous blank,
        //   then inserts the new one. The previous draft is meant to
        //   be ephemeral — calling startNewChat twice leaves only the
        //   most recent blank.
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        repo.startNewChatInProject(p.id)
        val second = repo.startNewChatInProject(p.id)
        val list = repo.projectChats.value[p.id]!!
        assertEquals(1, list.size)
        assertEquals(second.id, list[0].id)
        assertEquals("New chat", second.title)
    }

    @Test fun saveProjectChatMessagesUpdatesTranscriptAndTitle() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        val messages = listOf(
            PersistedChatMessage(
                id = "u1", role = PersistedChatMessage.Role.USER,
                content = "What's the difference between SSE and WebSockets?",
                timestampMillis = 1_700_000_000_000L,
            ),
        )
        repo.saveProjectChatMessages(p.id, chat.id, messages)
        val list = repo.projectChats.value[p.id]!!
        assertEquals(1, list[0].messages.size)
        assertTrue(list[0].title.startsWith("What's the difference"))
    }

    @Test fun saveProjectChatMessagesOnUnknownChatIsNoOp() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        repo.saveProjectChatMessages(
            p.id, "does-not-exist",
            listOf(
                PersistedChatMessage(
                    id = "u1", role = PersistedChatMessage.Role.USER,
                    content = "hi", timestampMillis = 0L,
                ),
            ),
        )
        assertEquals(emptyList<ProjectChatItem>(), repo.projectChats.value[p.id])
    }

    @Test fun projectChatMessagesReturnsMessagesForChat() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        val msgs = listOf(
            PersistedChatMessage(
                id = "u1", role = PersistedChatMessage.Role.USER,
                content = "hi", timestampMillis = 1L,
            ),
        )
        repo.saveProjectChatMessages(p.id, chat.id, msgs)
        assertEquals(msgs, repo.projectChatMessages(p.id, chat.id))
    }

    @Test fun projectChatMessagesOnUnknownChatReturnsEmpty() = runTest {
        val repo = InMemoryProjectRepository()
        assertEquals(emptyList<PersistedChatMessage>(), repo.projectChatMessages("missing", "missing"))
    }

    @Test fun projectChatSelectedModelRoundTrips() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        val model = AIModel(
            provider = ProviderId.Anthropic,
            modelID = "claude-3-5-sonnet-20241022",
            displayName = "Claude 3.5 Sonnet",
        )
        repo.saveProjectChatSelectedModel(p.id, chat.id, model)
        assertEquals(model, repo.projectChatSelectedModel(p.id, chat.id))
    }

    @Test fun renameProjectChatTrimsAndSetsFlags() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        repo.renameProjectChat(p.id, chat.id, "  Hello  ")
        val updated = repo.projectChats.value[p.id]!![0]
        assertEquals("Hello", updated.title)
        assertTrue(updated.titleIsUserEdited)
        assertTrue(updated.didAutoTitle)
    }

    @Test fun renameProjectChatWithBlankTitleIsNoOp() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        repo.renameProjectChat(p.id, chat.id, "   ")
        assertEquals("New chat", repo.projectChats.value[p.id]!![0].title)
    }

    @Test fun deleteProjectChatRemovesIt() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        repo.saveProjectChatMessages(
            p.id, chat.id,
            listOf(
                PersistedChatMessage(
                    id = "u1", role = PersistedChatMessage.Role.USER,
                    content = "hi", timestampMillis = 1L,
                ),
            ),
        )
        repo.deleteProjectChat(p.id, chat.id)
        assertEquals(emptyList<ProjectChatItem>(), repo.projectChats.value[p.id])
    }

    @Test fun archiveProjectChatSetsFlag() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        repo.saveProjectChatMessages(
            p.id, chat.id,
            listOf(
                PersistedChatMessage(
                    id = "u1", role = PersistedChatMessage.Role.USER,
                    content = "hi", timestampMillis = 1L,
                ),
            ),
        )
        repo.archiveProjectChat(p.id, chat.id)
        assertTrue(repo.projectChats.value[p.id]!![0].isArchived)
    }
}
