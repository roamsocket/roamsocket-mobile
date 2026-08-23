package app.roamsocket.core.chats

import app.roamsocket.core.chats.PersistedChatMessage.Role.ASSISTANT
import app.roamsocket.core.chats.PersistedChatMessage.Role.USER
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the in-memory chat history repository. The Android app
 * module wraps this with DataStore-backed persistence; the logic for
 * ordering, active-chat tracking, and blank-draft handling lives here.
 */
class InMemoryChatHistoryRepositoryTest {

    @Test
    fun newChatBecomesActiveAndAppearsInInternalSnapshot() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val id = repo.startNewChat()
        assertEquals(id, repo.activeChatId)
        // Blank drafts are hidden from `recents` (matches iOS) but the
        // active chat still exists in the internal snapshot for persistence.
        assertTrue(repo.recents.value.isEmpty())
        assertEquals(1, repo.snapshot().size)
        assertEquals(id, repo.snapshot().first().id)
    }

    @Test
    fun blankDraftsAreHiddenFromRecents() = runTest {
        val repo = InMemoryChatHistoryRepository()
        repo.startNewChat() // blank, hidden
        assertTrue(repo.recents.value.isEmpty())
        assertEquals(1, repo.snapshot().size)
    }

    @Test
    fun saveMessagesDerivesTitleAndUpdatesRecents() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val id = repo.startNewChat()
        val messages = listOf(
            msg("u1", USER, "What's the difference between SSE and WebSockets?"),
            msg("a1", ASSISTANT, "SSE is one-way, WebSockets are bidirectional."),
        )
        repo.saveMessages(id, messages)
        val recents = repo.recents.value
        assertEquals(1, recents.size)
        val chat = recents.first()
        assertEquals(2, chat.messages.size)
        assertEquals(messages.last().timestampMillis, chat.lastMessageAtMillis)
        // Title is derived from the first user message.
        assertTrue(chat.title.startsWith("What's the difference"))
        assertNotEquals(ChatHistoryItem.DEFAULT_TITLE, chat.title)
    }

    @Test
    fun saveMessagesOnUnknownIdIsANoOp() = runTest {
        val repo = InMemoryChatHistoryRepository()
        repo.saveMessages("does-not-exist", listOf(msg("u", USER, "hi")))
        assertTrue(repo.recents.value.isEmpty())
    }

    @Test
    fun openChatBubblesAnExistingRowToTheTop() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val first = repo.startNewChat()
        repo.saveMessages(first, listOf(msg("u", USER, "first")))
        val second = repo.startNewChat()
        repo.saveMessages(second, listOf(msg("u", USER, "second")))
        // Recent order: [second, first].
        assertEquals(second, repo.recents.value[0].id)
        // Opening the first chat moves it to the top.
        repo.openChat(first)
        assertEquals(first, repo.recents.value[0].id)
        assertEquals(first, repo.activeChatId)
    }

    @Test
    fun openChatAddsAnUnknownRowAsAStub() = runTest {
        val repo = InMemoryChatHistoryRepository()
        repo.openChat("not-in-store")
        assertEquals("not-in-store", repo.activeChatId)
        // The stub is a blank draft — it exists internally but stays
        // out of the visible Recents list (mirrors iOS).
        assertTrue(repo.recents.value.isEmpty())
        assertEquals(1, repo.snapshot().size)
        assertEquals("not-in-store", repo.snapshot().first().id)
    }

    @Test
    fun deleteChatRemovesAndClearsActive() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val id = repo.startNewChat()
        repo.saveMessages(id, listOf(msg("u", USER, "hi")))
        repo.deleteChat(id)
        assertTrue(repo.recents.value.isEmpty())
        assertNull(repo.activeChatId)
    }

    @Test
    fun discardActiveIfBlankDropsBlankDrafts() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val id = repo.startNewChat() // blank
        repo.discardActiveIfBlank()
        assertNull(repo.activeChatId)
        assertTrue(repo.snapshot().isEmpty())
    }

    @Test
    fun discardActiveIfBlankKeepsPopulatedChats() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val id = repo.startNewChat()
        repo.saveMessages(id, listOf(msg("u", USER, "hi")))
        repo.discardActiveIfBlank()
        assertEquals(id, repo.activeChatId)
        assertEquals(1, repo.recents.value.size)
    }

    @Test
    fun replaceAllLoadsPersistedChats() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val persisted = listOf(
            ChatHistoryItem(
                id = "x",
                title = "Resumed",
                lastMessageAtMillis = 1_000L,
                messages = listOf(msg("u", USER, "loaded from disk")),
            ),
        )
        repo.replaceAll(persisted)
        val recents = repo.recents.first()
        assertEquals(1, recents.size)
        assertEquals("Resumed", recents.first().title)
    }

    @Test
    fun startNewChatDiscardsPreviousBlankDrafts() = runTest {
        val repo = InMemoryChatHistoryRepository()
        repo.startNewChat() // blank
        repo.startNewChat() // also blank
        // Two starts should leave exactly one active blank draft in the
        // internal snapshot, not two.
        assertEquals(1, repo.snapshot().size)
    }

    @Test
    fun setModelWritesProviderAndModelId() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val id = repo.startNewChat()
        repo.saveMessages(id, listOf(msg("u", USER, "hi")))
        assertFalse(repo.snapshot().first().hasModelOverride)

        repo.setModel(id, ProviderId.OpenAI, "gpt-4o")
        val updated = repo.snapshot().first { it.id == id }
        assertTrue(updated.hasModelOverride)
        assertEquals(ProviderId.OpenAI, updated.resolvedProvider)
        assertEquals("gpt-4o", updated.selectedModel)
    }

    @Test
    fun setModelOnUnknownIdIsANoOp() = runTest {
        val repo = InMemoryChatHistoryRepository()
        repo.setModel("does-not-exist", ProviderId.Google, "gemini-2.0-flash")
        assertTrue(repo.snapshot().isEmpty())
    }

    @Test
    fun startIncognitoChatFlagsTheRowAndSetsForgetDeadline() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val id = repo.startIncognitoChat(IncognitoLifetime.ONE_HOUR)
        val row = repo.snapshot().first { it.id == id }
        assertTrue(row.isIncognito)
        assertEquals(IncognitoLifetime.ONE_HOUR, row.incognitoLifetime)
        // One hour from "now" — give it a generous window so the test
        // isn't flakey on slow CI.
        val now = System.currentTimeMillis()
        assertNotNull(row.forgetAtMillis)
        assertTrue(row.forgetAtMillis!! in now..(now + 65 * 60 * 1000L))
    }

    @Test
    fun onExitIncognitoHasNoForgetDeadline() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val id = repo.startIncognitoChat(IncognitoLifetime.ON_EXIT)
        val row = repo.snapshot().first { it.id == id }
        assertTrue(row.isIncognito)
        assertEquals(IncognitoLifetime.ON_EXIT, row.incognitoLifetime)
        assertNull(row.forgetAtMillis)
    }

    @Test
    fun saveMessagesResetsTheIncognitoCountdown() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val id = repo.startIncognitoChat(IncognitoLifetime.ONE_HOUR)
        val original = repo.snapshot().first { it.id == id }.forgetAtMillis!!
        // Sleep a beat so the reset is strictly later, then save a message.
        Thread.sleep(2)
        repo.saveMessages(id, listOf(msg("u", USER, "hi")))
        val after = repo.snapshot().first { it.id == id }.forgetAtMillis!!
        assertTrue(after > original)
    }

    @Test
    fun setIncognitoLifetimeResetsToTheNewWindow() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val id = repo.startIncognitoChat(IncognitoLifetime.ONE_HOUR)
        val before = repo.snapshot().first { it.id == id }.forgetAtMillis!!
        Thread.sleep(2)
        repo.setIncognitoLifetime(id, IncognitoLifetime.SIX_HOURS)
        val row = repo.snapshot().first { it.id == id }
        assertEquals(IncognitoLifetime.SIX_HOURS, row.incognitoLifetime)
        assertTrue(row.forgetAtMillis!! > before)
    }

    @Test
    fun forgetChatNowDropsIncognitoAndClearsActive() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val id = repo.startIncognitoChat(IncognitoLifetime.ONE_HOUR)
        repo.saveMessages(id, listOf(msg("u", USER, "secret")))
        assertEquals(1, repo.recents.value.size)
        repo.forgetChatNow(id)
        assertTrue(repo.recents.value.isEmpty())
        assertNull(repo.activeChatId)
    }

    @Test
    fun forgetActiveIfOnExitOnlyDropsOnExitChats() = runTest {
        val onExitRepo = InMemoryChatHistoryRepository()
        val onExitId = onExitRepo.startIncognitoChat(IncognitoLifetime.ON_EXIT)
        onExitRepo.saveMessages(onExitId, listOf(msg("u", USER, "burn after reading")))
        onExitRepo.forgetActiveIfOnExit()
        assertNull(onExitRepo.activeChatId)
        assertTrue(onExitRepo.recents.value.isEmpty())

        val timedRepo = InMemoryChatHistoryRepository()
        val timedId = timedRepo.startIncognitoChat(IncognitoLifetime.ONE_HOUR)
        timedRepo.saveMessages(timedId, listOf(msg("u", USER, "still here for an hour")))
        timedRepo.forgetActiveIfOnExit()
        // The timed chat stays put — it has a real deadline, not on-exit.
        assertEquals(timedId, timedRepo.activeChatId)
        assertEquals(1, timedRepo.recents.value.size)
    }

    @Test
    fun pruneExpiredIncognitoDropsOverdueChats() = runTest {
        val repo = InMemoryChatHistoryRepository()
        val expired = repo.startIncognitoChat(IncognitoLifetime.ONE_HOUR)
        // Save the first message BEFORE starting a second incognito —
        // mirrors the real usage pattern (user types, then opens a
        // new incognito) and the second `startIncognitoChat` would
        // otherwise discard the first as a blank draft.
        repo.saveMessages(expired, listOf(msg("u", USER, "old")))
        val fresh = repo.startIncognitoChat(IncognitoLifetime.ONE_HOUR)
        repo.saveMessages(fresh, listOf(msg("u", USER, "new")))
        // Hand-roll an "expired" row by rewriting the snapshot — that's
        // the only way to simulate the passage of time in a unit test.
        val now = System.currentTimeMillis()
        val overwritten = repo.snapshot().map { item ->
            if (item.id == expired) item.copy(forgetAtMillis = now - 1000L) else item
        }
        repo.replaceAll(overwritten)
        val dropped = repo.pruneExpiredIncognito()
        assertEquals(listOf(expired), dropped)
        val remaining = repo.recents.value.map { it.id }
        assertEquals(listOf(fresh), remaining)
    }

    private fun msg(id: String, role: PersistedChatMessage.Role, text: String) =
        PersistedChatMessage(id = id, role = role, content = text, timestampMillis = 1L)
}
