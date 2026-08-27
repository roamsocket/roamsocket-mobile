package app.roamsocket.android.ui.chats

import app.roamsocket.core.chats.PersistedChatMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatTitleGeneratorTest {

    private fun userMsg(content: String) = PersistedChatMessage(
        id = "u1", role = PersistedChatMessage.Role.USER,
        content = content, timestampMillis = 0L,
    )

    // -- heuristic ----------------------------------------------------------

    @Test fun heuristicFirstSixWords() {
        assertEquals(
            "What is the difference between SSE",
            ChatTitleGenerator.heuristic("What is the difference between SSE and WebSockets?"),
        )
    }

    @Test fun heuristicCapsAtMaxLength() {
        val long = "x".repeat(200)
        val out = ChatTitleGenerator.heuristic(long)
        assertTrue(out.length <= ChatTitleGenerator.MAX_TITLE_LENGTH)
        assertTrue(out.endsWith("\u2026"))
    }

    @Test fun heuristicEmptyReturnsEmpty() {
        assertEquals("", ChatTitleGenerator.heuristic(""))
        assertEquals("", ChatTitleGenerator.heuristic("    "))
    }

    // -- sanitize -----------------------------------------------------------

    @Test fun sanitizeStripsWrappingQuotes() {
        assertEquals("Hello", ChatTitleGenerator.sanitize("\"Hello\""))
        assertEquals("Hello", ChatTitleGenerator.sanitize("\u201CHello\u201D"))
    }

    @Test fun sanitizeStripsTitlePrefix() {
        assertEquals("Hello", ChatTitleGenerator.sanitize("Title: Hello"))
        assertEquals("Hello", ChatTitleGenerator.sanitize("name: Hello"))
    }

    @Test fun sanitizeStripsTrailingPeriod() {
        assertEquals("Hello", ChatTitleGenerator.sanitize("Hello."))
    }

    @Test fun sanitizeKeepsTrailingPeriodWhenMultiple() {
        // "v1.0." would lose the trailing period only if there's a
        // single '.' in the short string.
        assertEquals("v1.0.", ChatTitleGenerator.sanitize("v1.0."))
    }

    @Test fun sanitizeCapsLongTitles() {
        val long = "x".repeat(200)
        val out = ChatTitleGenerator.sanitize(long)
        assertTrue(out.length <= ChatTitleGenerator.MAX_TITLE_LENGTH)
    }

    @Test fun sanitizeEmptyReturnsEmpty() {
        assertEquals("", ChatTitleGenerator.sanitize(""))
    }
}
