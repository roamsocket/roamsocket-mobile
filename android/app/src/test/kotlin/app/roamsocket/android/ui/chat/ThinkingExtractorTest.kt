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

    // MARK: - New providers (added in this revision)

    @Test
    fun `Grok reasoning tag returns body and visible answer`() {
        val raw = "<xai:reasoning>Inspect the call graph.</xai:reasoning>\nThe fix is in PR #42."
        val r = ThinkingExtractor.extract(raw)
        assertEquals("Inspect the call graph.", r.thinking)
        assertEquals("The fix is in PR #42.", r.content)
    }

    @Test
    fun `Grok reasoning tag unclosed is treated as open`() {
        val raw = "Lead in\n<xai:reasoning>still working on it"
        val r = ThinkingExtractor.extract(raw)
        assertEquals("still working on it", r.thinking)
        assertEquals("Lead in", r.content)
    }

    @Test
    fun `Llama 3_1 reasoning special tokens are stripped as a block`() {
        val raw = """
            <|reasoning|>let me check the docs first<|/reasoning|>
            The answer is documented in section 4.
        """.trimIndent()
        val cleaned = ThinkingExtractor.stripControlTokens(raw)
        assertFalse(cleaned.contains("<|reasoning|>"))
        assertTrue(cleaned.contains("The answer is documented in section 4."))
    }

    @Test
    fun `Llama 2 system block is stripped entirely`() {
        val raw = """
            <<SYS>>You are a helpful assistant. Be concise.<</SYS>>
            The short answer is 42.
        """.trimIndent()
        val cleaned = ThinkingExtractor.stripControlTokens(raw)
        assertEquals("The short answer is 42.", cleaned)
    }

    @Test
    fun `ChatGLM output wrapper is stripped`() {
        val raw = "<output>The final answer is 42.</output>"
        assertEquals("The final answer is 42.", ThinkingExtractor.stripControlTokens(raw))
    }

    @Test
    fun `HTML comment reasoning leak is stripped`() {
        val raw = """
            <!-- I should think about this more carefully -->
            The answer is 42.
        """.trimIndent()
        val cleaned = ThinkingExtractor.stripControlTokens(raw)
        assertEquals("The answer is 42.", cleaned)
    }

    @Test
    fun `Anthropic invoke wrapper is stripped`() {
        val raw = """
            Let me look that up.
            <antml:invoke name="search">
            <query>swift regex</query>
            </antml:invoke>
            Here's what I found.
        """.trimIndent()
        val cleaned = ThinkingExtractor.stripControlTokens(ThinkingExtractor.stripToolCallXml(raw))
        assertFalse(cleaned.contains("<antml:invoke"))
        assertFalse(cleaned.contains("</antml:invoke"))
        assertTrue(cleaned.contains("Let me look that up."))
        assertTrue(cleaned.contains("Here's what I found."))
    }

    @Test
    fun `xAI tool_calls plural wrapper is stripped`() {
        val raw = """
            I'll search for that.
            <xai:tool_calls>
            <invoke name="search"><query>swift regex</query></invoke>
            </xai:tool_calls>
            Here you go.
        """.trimIndent()
        val cleaned = ThinkingExtractor.stripControlTokens(ThinkingExtractor.stripToolCallXml(raw))
        assertFalse(cleaned.contains("<xai:tool_calls"))
        assertFalse(cleaned.contains("</xai:tool_calls>"))
        assertTrue(cleaned.contains("I'll search for that."))
        assertTrue(cleaned.contains("Here you go."))
    }

    @Test
    fun `Llama end-of-sentence token is stripped`() {
        val raw = "Here's the answer.</s>"
        assertEquals("Here's the answer.", ThinkingExtractor.stripControlTokens(raw))
    }

    @Test
    fun `system prompt leak marker is stripped`() {
        val raw = """
            [SYSTEM_PROMPT]You are a helpful assistant. Be concise.

            The actual answer is 42.
        """.trimIndent()
        val cleaned = ThinkingExtractor.stripControlTokens(raw)
        assertTrue(cleaned.contains("The actual answer is 42."))
        assertFalse(cleaned.contains("[SYSTEM_PROMPT]"))
    }

    @Test
    fun `Qwen vision box tokens are stripped`() {
        val raw = "<|box_start|>image_pad<|box_end|>\nThe image shows a cat."
        val cleaned = ThinkingExtractor.stripControlTokens(raw)
        assertTrue(cleaned.contains("The image shows a cat."))
        assertFalse(cleaned.contains("<|box_start|>"))
    }

    @Test
    fun `all new reasoning tag shapes are recognized`() {
        // Regression: every tag name in the new alternation should
        // be picked up by the same paired pattern.
        val cases = listOf(
            "<think>x</think>" to "x",
            "<xai:reasoning>x</xai:reasoning>" to "x",
            "<xai:thinking>x</xai:thinking>" to "x",
            "<scratch_pad>x</scratch_pad>" to "x",
        )
        for ((raw, expected) in cases) {
            val r = ThinkingExtractor.extract(raw)
            assertEquals("raw: $raw", expected, r.thinking)
            assertTrue("raw: $raw", r.content.isEmpty())
        }
    }
}
