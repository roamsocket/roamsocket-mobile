package app.roamsocket.android.ui.chat

import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar

/**
 * Unit tests for the iOS `ChatGreeting` Kotlin port.
 */
class ChatGreetingTest {

    @Test
    fun `morning phrase is non-empty`() {
        val morning = calendar(2026, Calendar.AUGUST, 21, 10, 0)
        val phrase = ChatGreeting.phrase(morning.timeInMillis)
        assertTrue(phrase.isNotBlank())
    }

    @Test
    fun `night phrase is non-empty`() {
        val night = calendar(2026, Calendar.AUGUST, 21, 23, 30)
        val phrase = ChatGreeting.phrase(night.timeInMillis)
        assertTrue(phrase.isNotBlank())
    }

    @Test
    fun `same hour different day gives different phrase most of the time`() {
        // Seed-based rotation should typically differ across days. We
        // loop until we find a day that differs, capped at a few
        // attempts so a freak alignment doesn't hang the test.
        val base = calendar(2026, Calendar.AUGUST, 21, 10, 0)
        val basePhrase = ChatGreeting.phrase(base.timeInMillis)
        var foundDifferent = false
        for (day in 22..28) {
            val other = calendar(2026, Calendar.AUGUST, day, 10, 0)
            val otherPhrase = ChatGreeting.phrase(other.timeInMillis)
            if (otherPhrase != basePhrase) {
                foundDifferent = true
                break
            }
        }
        assertTrue("expected some day to rotate to a different phrase", foundDifferent)
    }

    @Test
    fun `late night late hours are recognised`() {
        val late = calendar(2026, Calendar.AUGUST, 21, 3, 0)
        val phrase = ChatGreeting.phrase(late.timeInMillis)
        // Sanity check: the late-night pool should be one of the
        // canonical lines. We just ensure it isn't the same as a
        // morning phrase.
        val morning = calendar(2026, Calendar.AUGUST, 21, 10, 0)
        assertNotEquals(ChatGreeting.phrase(morning.timeInMillis), phrase)
    }

    private fun calendar(year: Int, month: Int, day: Int, hour: Int, minute: Int): Calendar =
        Calendar.getInstance().apply {
            clear()
            set(year, month, day, hour, minute)
        }
}
