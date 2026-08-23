package app.roamsocket.android.ui.markdown

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [MessageSegmentParser]. The parser is pure (no
 * `Context`, no Android dependencies) so plain JUnit is sufficient.
 */
internal class MessageSegmentParserTest {

    @Test
    fun `plain markdown produces a single MarkdownBody`() {
        val raw = "# Hello\n\nThis is **bold** text."
        val segments = MessageSegmentParser.parse(raw)

        assertEquals(1, segments.size)
        assertEquals(MessageSegment.MarkdownBody(raw), segments[0])
    }

    @Test
    fun `markdown-fenced block becomes a SnippetBlock surrounded by MarkdownBody`() {
        val raw = """
            Here is some intro prose.

            ```markdown
            # Hello
            ```

            Trailing prose.
        """.trimIndent()

        val segments = MessageSegmentParser.parse(raw)

        assertEquals(3, segments.size)
        // First: leading prose
        assertTrue(segments[0] is MessageSegment.MarkdownBody)
        // Middle: snippet
        val snippet = segments[1] as MessageSegment.SnippetBlock
        assertEquals(SnippetKind.MARKDOWN, snippet.kind)
        assertEquals("markdown", snippet.language)
        assertEquals("# Hello", snippet.code)
        // Last: trailing prose
        assertTrue(segments[2] is MessageSegment.MarkdownBody)
    }

    @Test
    fun `html-fenced block becomes a HTML snippet`() {
        val raw = "```html\n<p>Hi</p>\n```"
        val segments = MessageSegmentParser.parse(raw)

        assertEquals(1, segments.size)
        val snippet = segments[0] as MessageSegment.SnippetBlock
        assertEquals(SnippetKind.HTML, snippet.kind)
        assertEquals("html", snippet.language)
        assertEquals("<p>Hi</p>", snippet.code)
    }

    @Test
    fun `md, mdx, gfm aliases all map to MARKDOWN`() {
        listOf("md", "mdx", "gfm").forEach { alias ->
            val raw = "```$alias\n# X\n```"
            val segments = MessageSegmentParser.parse(raw)
            assertEquals("alias=$alias", 1, segments.size)
            val snippet = segments[0] as MessageSegment.SnippetBlock
            assertEquals("alias=$alias", SnippetKind.MARKDOWN, snippet.kind)
            assertEquals("alias=$alias", alias, snippet.language)
        }
    }

    @Test
    fun `htm and xhtml aliases map to HTML (case-insensitive, trimmed)`() {
        listOf("htm", "xhtml", "HTML", "  Html  ").forEach { alias ->
            val raw = "```$alias\n<p>x</p>\n```"
            val segments = MessageSegmentParser.parse(raw)
            assertEquals("alias='$alias'", 1, segments.size)
            val snippet = segments[0] as MessageSegment.SnippetBlock
            assertEquals("alias='$alias'", SnippetKind.HTML, snippet.kind)
        }
    }

    @Test
    fun `non-snippet language fences fall through into surrounding markdown`() {
        val raw = """
            Intro.

            ```python
            def hi():
                pass
            ```

            Outro.
        """.trimIndent()

        val segments = MessageSegmentParser.parse(raw)

        // The python fence is part of the middle MarkdownBody — not a
        // standalone segment. So the parser returns 3 segments and the
        // middle one is MarkdownBody containing the fence.
        assertEquals(3, segments.size)
        assertTrue(segments[0] is MessageSegment.MarkdownBody)
        assertTrue(segments[1] is MessageSegment.MarkdownBody)
        val middle = segments[1] as MessageSegment.MarkdownBody
        assertTrue(
            "middle segment should contain the python fence",
            middle.text.contains("```python"),
        )
        assertTrue(
            "middle segment should contain the code body",
            middle.text.contains("def hi()"),
        )
        assertTrue(segments[2] is MessageSegment.MarkdownBody)
    }

    @Test
    fun `trailing newline after fence open is stripped`() {
        val raw = "```markdown\n\n# Hello\n```"
        val segments = MessageSegmentParser.parse(raw)

        assertEquals(1, segments.size)
        val snippet = segments[0] as MessageSegment.SnippetBlock
        // The leading blank line after the fence open should be
        // stripped (matches the iOS parser behaviour).
        assertEquals("# Hello", snippet.code)
    }

    @Test
    fun `empty input returns an empty list`() {
        assertEquals(emptyList<MessageSegment>(), MessageSegmentParser.parse(""))
    }
}
