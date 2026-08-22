package app.roamsocket.android.ui.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the iOS `ThinkingExtractor` Kotlin port.
 *
 * Mirrors the cases exercised by the iOS XCTest suite (extracted
 * blocks, streaming open/partial tags, leaked provider tool-call XML).
 */
class ThinkingExtractorTest {

    @Test
    fun `empty input returns null thinking and empty content`() {
        val r = ThinkingExtractor.extract("")
        assertNull(r.thinking)
        assertEquals("", r.content)
    }

    @Test
    fun `paired think blocks are extracted and stripped from content`() {
        val raw = """
            <think>
            Let me check the user's intent.
            </think>
            Here is my answer.
        """.trimIndent()
        val r = ThinkingExtractor.extract(raw)
        assertNotNull(r.thinking)
        assertTrue(r.thinking!!.contains("Let me check"))
        assertTrue(r.content.contains("Here is my answer."))
        assertFalse(r.content.contains("<think>"))
    }

    @Test
    fun `multiple think blocks are joined with blank lines`() {
        val raw = """
            <think>First thought</think>
            Visible line 1.
            <think>Second thought</think>
            Visible line 2.
        """.trimIndent()
        val r = ThinkingExtractor.extract(raw)
        val thinking = r.thinking ?: error("expected thinking")
        assertTrue(thinking.contains("First thought"))
        assertTrue(thinking.contains("Second thought"))
        assertTrue(r.content.contains("Visible line 1."))
        assertTrue(r.content.contains("Visible line 2."))
    }

    @Test
    fun `thinking tag names other than think are also extracted`() {
        val raw = "<reflection>step back</reflection>\nAnswer."
        val r = ThinkingExtractor.extract(raw)
        assertEquals("step back", r.thinking)
        assertEquals("Answer.", r.content)
    }

    @Test
    fun `unclosed open tag is treated as thinking with empty body`() {
        val raw = "<think>in progress reasoning"
        val r = ThinkingExtractor.extract(raw)
        assertNotNull(r.thinking)
        assertEquals("in progress reasoning", r.thinking)
        assertEquals("", r.content)
    }

    @Test
    fun `partial open tag at the end of stream is hidden`() {
        val raw = "User-visible text\n<thin"
        val r = ThinkingExtractor.extract(raw)
        assertNotNull(r.thinking)
        assertTrue(r.content.startsWith("User-visible text"))
        assertFalse(r.content.contains("<thin"))
    }

    @Test
    fun `antml thinking is extracted and stripped`() {
        val raw = "<antml:thinking>model reasoning</antml:thinking>Visible reply"
        val r = ThinkingExtractor.extract(raw)
        assertEquals("model reasoning", r.thinking)
        assertEquals("Visible reply", r.content)
    }

    @Test
    fun `plain text with no tags has no thinking`() {
        val r = ThinkingExtractor.extract("Just a normal answer.")
        assertNull(r.thinking)
        assertEquals("Just a normal answer.", r.content)
    }

    @Test
    fun `minimax tool call XML is stripped from content`() {
        val raw = """
            <think>plan</think>
            <tool_call>
              <invoke name="bash"><command>ls</command></invoke>
            </tool_call>
            Here's what I did.
        """.trimIndent()
        val cleaned = ThinkingExtractor.stripToolCallXml(raw)
        assertFalse(cleaned.contains("<tool_call>"))
        assertFalse(cleaned.contains("<invoke"))
        assertTrue(cleaned.contains("Here's what I did."))
    }

    @Test
    fun `mistral control tokens are stripped`() {
        val raw = "<|im_start|>user\nhello<|im_end|>"
        val cleaned = ThinkingExtractor.stripControlTokens(raw)
        assertEquals("user\nhello", cleaned)
    }

    @Test
    fun `plain visible text removes thinking blocks`() {
        val raw = "<think>scratch</think>\nVisible line."
        assertEquals("Visible line.", ThinkingExtractor.plainVisibleText(raw))
    }
}
