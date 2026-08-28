package app.roamsocket.core.projects

import org.junit.Assert.assertEquals
import org.junit.Test

class MemoryCommandParserTest {

    @Test fun emptyCommandReturnsMemoryUnchanged() {
        assertEquals("", MemoryCommandParser.apply("", ""))
        assertEquals("hello", MemoryCommandParser.apply("hello", "   "))
    }

    @Test fun forgetRemovesMatchingLine() {
        val before = "\u2022 Likes dark mode\n\n\u2022 Prefers concise replies"
        val after = MemoryCommandParser.apply(before, "forget dark mode")
        assertEquals("\u2022 Prefers concise replies", after)
    }

    @Test fun forgetCaseInsensitive() {
        val before = "\u2022 Likes DARK mode\n\n\u2022 Prefers concise replies"
        val after = MemoryCommandParser.apply(before, "forget dark")
        assertEquals("\u2022 Prefers concise replies", after)
    }

    @Test fun forgetWithNoMatchAppendsNote() {
        val before = "\u2022 Likes dark mode"
        val after = MemoryCommandParser.apply(before, "forget coffee")
        assertEquals("\u2022 Likes dark mode\n\nNote: user asked to forget \u201Ccoffee\u201D.", after)
    }

    @Test fun forgetIntoEmptyMemoryAppendsNote() {
        val after = MemoryCommandParser.apply("", "forget coffee")
        assertEquals("Note: user asked to forget \u201Ccoffee\u201D.", after)
    }

    @Test fun rememberThatIAppendsBullet() {
        val after = MemoryCommandParser.apply("", "remember that I like coffee")
        assertEquals("\u2022 Like coffee", after)
    }

    @Test fun rememberThatAppendsBullet() {
        val after = MemoryCommandParser.apply("", "remember that Swift is great")
        assertEquals("\u2022 Swift is great", after)
    }

    @Test fun rememberAppendsBullet() {
        val after = MemoryCommandParser.apply("", "remember I prefer tabs")
        assertEquals("\u2022 I prefer tabs", after)
    }

    @Test fun freeformAppendsBullet() {
        val after = MemoryCommandParser.apply("", "Project ships Friday")
        assertEquals("\u2022 Project ships Friday", after)
    }

    @Test fun rememberAppendsToExistingMemory() {
        val before = "\u2022 Likes dark mode"
        val after = MemoryCommandParser.apply(before, "remember I like coffee")
        assertEquals("\u2022 Likes dark mode\n\n\u2022 I like coffee", after)
    }
}
