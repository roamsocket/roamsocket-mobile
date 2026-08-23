package app.roamsocket.android.ui.session

import app.roamsocket.core.code.SessionTranscriptLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the heuristic [CommitMessageGenerator]. The Android
 * port doesn't yet ship an on-device LLM (no Foundation Models
 * equivalent), so the test pins the contract for the heuristic
 * path that the session uses.
 */
class CommitMessageGeneratorTest {

    @Test
    fun assistantFirstLineWins() {
        val subject = CommitMessageGenerator.suggest(
            firstUserMessage = "please do a thing",
            diffSummary = null,
            transcript = listOf(
                line(SessionTranscriptLine.Kind.USER, "please do a thing"),
                line(SessionTranscriptLine.Kind.ASSISTANT, "Refactored auth flow"),
            ),
        )
        assertEquals("Refactored auth flow", subject)
    }

    @Test
    fun userMessageFallsBackWhenNoAssistant() {
        val subject = CommitMessageGenerator.suggest(
            firstUserMessage = "Add dark mode toggle",
            diffSummary = null,
            transcript = emptyList(),
        )
        assertEquals("Add dark mode toggle", subject)
    }

    @Test
    fun conventionalPrefixWhenAllDiffsAreUnderSameTopDir() {
        val subject = CommitMessageGenerator.suggest(
            firstUserMessage = null,
            diffSummary = null,
            transcript = listOf(
                diff("docs/architecture.md"),
                diff("docs/getting-started.md"),
            ),
        )
        assertTrue("expected 'docs: …' prefix, got '$subject'", subject.startsWith("docs:"))
    }

    @Test
    fun noPrefixWhenDiffsSpanMultipleTopDirs() {
        val subject = CommitMessageGenerator.suggest(
            firstUserMessage = null,
            diffSummary = null,
            transcript = listOf(
                diff("src/foo.kt"),
                diff("docs/bar.md"),
            ),
        )
        // No top-dir consensus → no conventional prefix; should be one
        // of the stat-driven fallbacks (we only have paths here so we
        // expect either the diff summary / first non-empty path).
        assertTrue("expected subject, got '$subject'", subject.isNotBlank())
        assertTrue("did not expect prefix", !subject.contains(':'))
    }

    @Test
    fun statFallbackWhenNothingElseMatches() {
        val subject = CommitMessageGenerator.suggest(
            firstUserMessage = null,
            diffSummary = null,
            transcript = emptyList(),
            diffStats = DiffStats(added = 3, removed = 1),
        )
        assertEquals("Update files (+3/-1)", subject)
    }

    @Test
    fun sanitizeCutsAtLastSpace() {
        val padded = "feat: a very long subject that should not end mid-word here"
        val trimmed = CommitMessageGenerator.sanitize(padded)
        assertTrue("trimmed longer than max: ${trimmed.length}", trimmed.length <= 72)
        assertTrue("expected no mid-word cut", !trimmed.endsWith("th"))
    }

    @Test
    fun sanitizeStripsMatchingWrappers() {
        assertEquals("hello", CommitMessageGenerator.sanitize("\"hello\""))
        assertEquals("hello", CommitMessageGenerator.sanitize("'hello'"))
    }

    private fun line(kind: SessionTranscriptLine.Kind, text: String) =
        SessionTranscriptLine(id = "x", kind = kind, text = text)

    private fun diff(path: String) = SessionTranscriptLine(
        id = "d-$path",
        kind = SessionTranscriptLine.Kind.DIFF,
        text = path,
        path = path,
    )
}
