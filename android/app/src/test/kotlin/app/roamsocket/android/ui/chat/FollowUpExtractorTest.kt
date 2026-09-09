package app.roamsocket.android.ui.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the iOS `FollowUpExtractor` Kotlin port.
 *
 * Mirrors the cases exercised by the iOS XCTest suite
 * (`ios/AnyProvCore/Tests/.../FollowUpExtractorTests.swift`) so a
 * change on one side that diverges from the other fails a test
 * instead of shipping. The shared cross-core fixture lives at
 * `docs/parity/follow-up-cases.json` and is also loaded by
 * `ParityTest.kt` on the JVM side.
 */
class FollowUpExtractorTest {

    // MARK: - Bracket form

    @Test
    fun `empty input produces no suggestions`() {
        val r = FollowUpExtractor.extract("")
        assertEquals("", r.content)
        assertEquals(emptyList<String>(), r.suggestions)
        assertFalse(r.hasSuggestions)
    }

    @Test
    fun `input without marker is unchanged`() {
        val raw = "Here is a normal assistant reply with no suggestions."
        val r = FollowUpExtractor.extract(raw)
        assertEquals(raw, r.content)
        assertEquals(emptyList<String>(), r.suggestions)
    }

    @Test
    fun `single bracket marker yields suggestions`() {
        val raw = "Some prose before. [SUGGEST: shorter follow-up | a different angle | a code example] And prose after."
        val r = FollowUpExtractor.extract(raw)
        assertEquals(
            listOf("shorter follow-up", "a different angle", "a code example"),
            r.suggestions
        )
        assertFalse(r.content.contains("[SUGGEST:"))
        assertTrue(r.content.contains("Some prose before."))
        assertTrue(r.content.contains("And prose after."))
    }

    @Test
    fun `bracket keyword is case-insensitive`() {
        val r = FollowUpExtractor.extract("hi [suggest: A | B] bye")
        assertEquals(listOf("A", "B"), r.suggestions)
    }

    @Test
    fun `multiple bracket markers are merged`() {
        val raw = "[SUGGEST: one | two] middle [SUGGEST: three] tail"
        val r = FollowUpExtractor.extract(raw)
        assertEquals(listOf("one", "two", "three"), r.suggestions)
        assertFalse(r.content.contains("[SUGGEST:"))
    }

    @Test
    fun `empty bracket labels are dropped`() {
        val raw = "[SUGGEST: a |  | b |   | c]"
        val r = FollowUpExtractor.extract(raw)
        assertEquals(listOf("a", "b", "c"), r.suggestions)
    }

    @Test
    fun `long bracket label is truncated`() {
        val long = "x".repeat(FollowUpExtractor.MAX_LABEL_LENGTH + 50)
        val raw = "[SUGGEST: $long]"
        val r = FollowUpExtractor.extract(raw)
        assertEquals(1, r.suggestions.size)
        assertTrue(r.suggestions[0].length <= FollowUpExtractor.MAX_LABEL_LENGTH)
        assertTrue(r.suggestions[0].endsWith("…"))
    }

    @Test
    fun `bracket marker at start and end of message`() {
        val start = FollowUpExtractor.extract("[SUGGEST: only] rest of message")
        assertEquals(listOf("only"), start.suggestions)
        assertTrue(start.content.startsWith("rest of message"))

        val end = FollowUpExtractor.extract("intro [SUGGEST: only]")
        assertEquals(listOf("only"), end.suggestions)
        assertTrue(end.content.startsWith("intro"))
    }

    @Test
    fun `bracket marker only message`() {
        val raw = "[SUGGEST: a | b | c]"
        val r = FollowUpExtractor.extract(raw)
        assertEquals(listOf("a", "b", "c"), r.suggestions)
        assertEquals("", r.content)
    }

    @Test
    fun `bracket whitespace in labels is trimmed`() {
        val r = FollowUpExtractor.extract("[SUGGEST:   padded label   |   another  ]")
        assertEquals(listOf("padded label", "another"), r.suggestions)
    }

    // MARK: - Angle-bracket form

    @Test
    fun `angle bracket marker yields single label`() {
        val raw = "Reply body. <suggest>shorter version</suggest>"
        val r = FollowUpExtractor.extract(raw)
        assertEquals(listOf("shorter version"), r.suggestions)
        assertFalse(r.content.contains("<suggest>"))
    }

    @Test
    fun `multiple angle bracket markers are merged`() {
        val raw = "<suggest>first</suggest> and <suggest>second</suggest>"
        val r = FollowUpExtractor.extract(raw)
        assertEquals(listOf("first", "second"), r.suggestions)
    }

    @Test
    fun `angle bracket is case-insensitive`() {
        val r = FollowUpExtractor.extract("intro <Suggest>foo</Suggest> tail")
        assertEquals(listOf("foo"), r.suggestions)
    }

    @Test
    fun `angle bracket handles attributes`() {
        val raw = "body. <suggest id=\"1\">label a</suggest> then <suggest id=\"2\">label b</suggest>"
        val r = FollowUpExtractor.extract(raw)
        assertEquals(listOf("label a", "label b"), r.suggestions)
    }

    // MARK: - Numbered list form

    @Test
    fun `numbered list after follow-up heading is extracted`() {
        val raw = """
            Here is the answer.

            Next steps:
            1. Try the smaller API
            2. Add retry logic
            3. Switch to streaming
        """.trimIndent()
        val r = FollowUpExtractor.extract(raw)
        assertEquals(
            listOf("Try the smaller API", "Add retry logic", "Switch to streaming"),
            r.suggestions
        )
        assertFalse(r.content.contains("Next steps:"))
        assertFalse(r.content.contains("1. Try the smaller API"))
    }

    @Test
    fun `numbered list with parenthesis separator`() {
        val raw = """
            Body text.

            You might want to:
            1) Make the variable optional
            2) Add a default value
        """.trimIndent()
        val r = FollowUpExtractor.extract(raw)
        assertEquals(
            listOf("Make the variable optional", "Add a default value"),
            r.suggestions
        )
    }

    @Test
    fun `numbered list with markdown heading prefix`() {
        val raw = """
            Answer.

            **Next steps:**
            1. Refactor the parser
            2. Add a regression test
        """.trimIndent()
        val r = FollowUpExtractor.extract(raw)
        assertEquals(listOf("Refactor the parser", "Add a regression test"), r.suggestions)
    }

    @Test
    fun `numbered list without heading is not extracted`() {
        val raw = """
            The issue has two parts.

            1. The first part is misnamed
            2. The second part is duplicated
        """.trimIndent()
        val r = FollowUpExtractor.extract(raw)
        assertEquals(emptyList<String>(), r.suggestions)
        assertTrue(r.content.contains("1. The first part is misnamed"))
    }

    @Test
    fun `numbered list with single item is not extracted`() {
        val raw = """
            Here you go.

            Next steps:
            1. That's it.
        """.trimIndent()
        val r = FollowUpExtractor.extract(raw)
        assertEquals(emptyList<String>(), r.suggestions)
    }

    // MARK: - Mixed forms + dedup

    @Test
    fun `bracket and angle bracket are not both used`() {
        val raw = """
            Body.

            [SUGGEST: A | B]

            <suggest>C</suggest>
        """.trimIndent()
        val r = FollowUpExtractor.extract(raw)
        assertEquals(listOf("A", "B"), r.suggestions)
    }

    @Test
    fun `angle bracket and numbered list do not mix`() {
        val raw = """
            Body.

            <suggest>first</suggest>

            Next steps:
            1. second
            2. third
        """.trimIndent()
        val r = FollowUpExtractor.extract(raw)
        assertEquals(listOf("first"), r.suggestions)
    }

    @Test
    fun `duplicate labels are de-duplicated`() {
        val raw = "[SUGGEST: retry | retry | Retry]"
        val r = FollowUpExtractor.extract(raw)
        assertEquals(listOf("retry"), r.suggestions)
    }

    @Test
    fun `suggestions are capped at max suggestions`() {
        val labels = (1..12).joinToString(" | ") { "option $it" }
        val raw = "[SUGGEST: $labels]"
        val r = FollowUpExtractor.extract(raw)
        assertEquals(FollowUpExtractor.MAX_SUGGESTIONS, r.suggestions.size)
    }

    // MARK: - Realistic shapes

    @Test
    fun `follow up after long prose paragraph`() {
        val raw = """
            The cause is that the cache key includes a timestamp, so every request lands
            on a cold path. Bumping the TTL should fix it; you can also invalidate on
            dependency changes.

            [SUGGEST: Show me the diff | Bump the TTL | Add a unit test for the cache key]
        """.trimIndent()
        val r = FollowUpExtractor.extract(raw)
        assertEquals(
            listOf("Show me the diff", "Bump the TTL", "Add a unit test for the cache key"),
            r.suggestions
        )
        assertTrue(r.content.startsWith("The cause is that the cache key"))
        assertTrue(r.content.contains("Bumping the TTL should fix it"))
        assertFalse(r.content.contains("[SUGGEST:"))
    }

    @Test
    fun `marker inside code fence is not extracted`() {
        val raw = """
            Use this snippet:

            ```
            [SUGGEST: do not extract | this is a literal example]
            ```

            That's it.
        """.trimIndent()
        val r = FollowUpExtractor.extract(raw)
        assertEquals(emptyList<String>(), r.suggestions)
        assertTrue(r.content.contains("[SUGGEST: do not extract"))
    }
}
