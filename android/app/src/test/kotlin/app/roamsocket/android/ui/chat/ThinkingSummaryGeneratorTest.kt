package app.roamsocket.android.ui.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [ThinkingSummaryGenerator.heuristicSummary], the
 * one-line label generator for the collapsed Thinking row. The
 * chat view-model now calls this on stream complete (it used to
 * be reachable only via the [ThinkingBlock] view layer) so the
 * test exercises the public API directly.
 *
 * Mirrors the iOS `ThinkingSummaryGenerator` heuristics tests at
 * `ios/App/Tests/.../ThinkingSummaryGeneratorTests.swift`.
 */
class ThinkingSummaryGeneratorTest {

    @Test
    fun `empty input returns Thinking placeholder`() {
        assertEquals("Thinking…", ThinkingSummaryGenerator.heuristicSummary(""))
        assertEquals("Thinking…", ThinkingSummaryGenerator.heuristicSummary("   \n  "))
    }

    @Test
    fun `first sentence is used when long enough`() {
        val summary = ThinkingSummaryGenerator.heuristicSummary(
            "Picking the right index. Then the rest of the reasoning, which should be dropped from the summary because the first sentence already qualifies."
        )
        assertEquals("Picking the right index", summary)
    }

    @Test
    fun `long first sentence is clipped at a word boundary`() {
        val longSentence = "x".repeat(200)
        val summary = ThinkingSummaryGenerator.heuristicSummary(longSentence)
        assertTrue("expected summary <= 56 chars, got ${summary.length}", summary.length <= 56)
        assertTrue("expected summary to end with ellipsis, got '$summary'", summary.endsWith("…"))
    }

    @Test
    fun `short first sentence below 12 chars falls through to the full text`() {
        val summary = ThinkingSummaryGenerator.heuristicSummary("ok. then more reasoning follows")
        // First sentence "ok" is too short → fall through to the full
        // text, clipped at a word boundary.
        assertTrue(summary.startsWith("ok"))
        assertTrue(summary.contains("then more reasoning follows"))
    }
}
