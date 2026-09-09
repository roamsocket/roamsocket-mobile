package app.roamsocket.android.ui.chat

import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.chats.PersistedToolStep
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests the structured assistant-message fields added in the
 * "structured ChatMessage" revision:
 *
 *  * `ChatMessage.Assistant.thoughtProcess` / `thoughtSummary`
 *  * `ChatMessage.Assistant.toolCalls`
 *  * `ChatMessage.Assistant.memoryActivityIDs`
 *  * `ChatMessage.Assistant.isStreaming`
 *
 * plus the [toPersisted] / [toUi] round-trip so the in-memory and
 * on-disk shapes stay in lockstep. The iOS counterpart lives at
 * `ios/App/Tests/.../ChatMessageStructuredTest.swift` (mirrored
 * 1:1 so a regression on one side fails the same way on the other).
 */
class ChatMessageStructuredTest {

    // MARK: - Defaults

    @Test
    fun `Assistant defaults are all empty`() {
        val msg = ChatMessage.Assistant(text = "hi", timestampMillis = 1L)
        assertFalse(msg.isStreaming)
        assertNull(msg.thoughtProcess)
        assertNull(msg.thoughtSummary)
        assertTrue(msg.toolCalls.isEmpty())
        assertTrue(msg.memoryActivityIDs.isEmpty())
    }

    @Test
    fun `Assistant populates every field when given`() {
        val msg = ChatMessage.Assistant(
            text = "answer",
            timestampMillis = 1L,
            isStreaming = true,
            thoughtProcess = "thinking…",
            thoughtSummary = "Plan the answer",
            toolCalls = listOf(
                ToolCall(
                    id = "t-1",
                    name = "web_search",
                    summary = "Searched the web for \"swift\"",
                    status = ToolCall.Status.Completed,
                ),
            ),
            memoryActivityIDs = listOf("a-1", "a-2"),
        )
        assertTrue(msg.isStreaming)
        assertEquals("thinking…", msg.thoughtProcess)
        assertEquals("Plan the answer", msg.thoughtSummary)
        assertEquals(1, msg.toolCalls.size)
        assertEquals(listOf("a-1", "a-2"), msg.memoryActivityIDs)
    }

    // MARK: - toPersisted

    @Test
    fun `toPersisted writes structured assistant fields onto the on-disk shape`() {
        val msg = ChatMessage.Assistant(
            text = "Visible body.",
            timestampMillis = 42L,
            thoughtProcess = "Reasoning body.",
            thoughtSummary = "Picking the right index",
            toolCalls = listOf(
                ToolCall(
                    id = "t-1",
                    name = "web_search",
                    summary = "Searched the web",
                    detail = "3 results",
                    result = "First hit",
                    status = ToolCall.Status.Completed,
                ),
                ToolCall(
                    id = "t-2",
                    name = "wikipedia",
                    summary = "Pulled Wikipedia article",
                    status = ToolCall.Status.Failed(message = "no article"),
                ),
            ),
        )
        val persisted = msg.toPersisted()
        assertEquals(PersistedChatMessage.Role.ASSISTANT, persisted.role)
        assertEquals("Visible body.", persisted.content)
        assertEquals("Reasoning body.", persisted.thoughtProcess)
        assertEquals("Picking the right index", persisted.thoughtSummary)
        // Live running state and result bodies are NOT persisted —
        // they're only meaningful while the bubble is on screen.
        assertEquals(2, persisted.toolSteps.size)
        assertEquals("t-1", persisted.toolSteps[0].id)
        assertEquals("web_search", persisted.toolSteps[0].name)
        assertEquals("Searched the web", persisted.toolSteps[0].summary)
        assertEquals("3 results", persisted.toolSteps[0].detail)
        assertEquals("wikipedia", persisted.toolSteps[1].name)
        assertNull(persisted.toolSteps[1].detail)
    }

    @Test
    fun `toPersisted drops empty tool calls and memory activity IDs`() {
        val msg = ChatMessage.Assistant(
            text = "no metadata here",
            timestampMillis = 1L,
        )
        val persisted = msg.toPersisted()
        assertTrue(persisted.toolSteps.isEmpty())
        // `memoryActivityIDs` lives only on the in-memory shape so it
        // can't leak to disk; verify the converter didn't introduce
        // a `memoryActivityIDs` field on the persisted row.
        assertFalse(persisted.toString().contains("memoryActivityIDs"))
    }

    // MARK: - toUi

    @Test
    fun `toUi restores structured assistant fields from the on-disk shape`() {
        val persisted = PersistedChatMessage(
            id = "a-1",
            role = PersistedChatMessage.Role.ASSISTANT,
            content = "answer",
            timestampMillis = 7L,
            thoughtProcess = "thinking…",
            thoughtSummary = "Pick the index",
            toolSteps = listOf(
                PersistedToolStep(
                    id = "t-1",
                    name = "web_search",
                    summary = "Searched",
                    detail = "5 sources",
                ),
            ),
        )
        val msg = persisted.toUi() as ChatMessage.Assistant
        assertEquals("answer", msg.text)
        assertEquals(7L, msg.timestampMillis)
        assertFalse(msg.isStreaming)
        assertEquals("thinking…", msg.thoughtProcess)
        assertEquals("Pick the index", msg.thoughtSummary)
        assertEquals(1, msg.toolCalls.size)
        val tool = msg.toolCalls[0]
        assertEquals("t-1", tool.id)
        assertEquals("web_search", tool.name)
        assertEquals("Searched", tool.summary)
        assertEquals("5 sources", tool.detail)
        // Restored tool steps are always Completed (the live
        // running state is dropped before persisting).
        assertEquals(ToolCall.Status.Completed, tool.status)
    }

    @Test
    fun `toUi on a legacy assistant row yields an assistant with null thinking and empty tool calls`() {
        val persisted = PersistedChatMessage(
            id = "a-legacy",
            role = PersistedChatMessage.Role.ASSISTANT,
            content = "Old chat from before structured fields.",
            timestampMillis = 1L,
        )
        val msg = persisted.toUi() as ChatMessage.Assistant
        assertEquals("Old chat from before structured fields.", msg.text)
        assertNull(msg.thoughtProcess)
        assertNull(msg.thoughtSummary)
        assertTrue(msg.toolCalls.isEmpty())
    }

    // MARK: - Round-trip

    @Test
    fun `assistant message round-trips through persisted`() {
        val original = ChatMessage.Assistant(
            text = "Visible body.",
            timestampMillis = 42L,
            thoughtProcess = "Reasoning body.",
            thoughtSummary = "Picking the right index",
            toolCalls = listOf(
                ToolCall(
                    id = "t-1",
                    name = "web_search",
                    summary = "Searched the web",
                    detail = "3 results",
                ),
            ),
        )
        val persisted = original.toPersisted()
        val restored = persisted.toUi() as ChatMessage.Assistant
        assertEquals(original.text, restored.text)
        assertEquals(original.timestampMillis, restored.timestampMillis)
        assertEquals(original.thoughtProcess, restored.thoughtProcess)
        assertEquals(original.thoughtSummary, restored.thoughtSummary)
        // The ToolCall's `id`/`name`/`summary`/`detail` survive the
        // round-trip. `result` and `status` are runtime-only (always
        // reset on restore).
        assertEquals(original.toolCalls.size, restored.toolCalls.size)
        assertEquals(original.toolCalls[0].id, restored.toolCalls[0].id)
        assertEquals(original.toolCalls[0].name, restored.toolCalls[0].name)
        assertEquals(original.toolCalls[0].summary, restored.toolCalls[0].summary)
        assertEquals(original.toolCalls[0].detail, restored.toolCalls[0].detail)
        assertEquals(ToolCall.Status.Completed, restored.toolCalls[0].status)
    }
}
