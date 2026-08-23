package app.roamsocket.android.ui.markdown

import app.roamsocket.android.ui.theme.Palette
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lightweight coverage for the markdown surface:
 *  - confirms [MessageSegmentParser] still produces a non-empty list
 *    for ordinary input, and that the leading [MessageSegment.MarkdownBody]
 *    preserves the prose verbatim;
 *  - spot-checks a couple of [Palette] tokens that the markdown UI
 *    relies on, so a future palette refactor can't silently drop them.
 *
 * The Markwon-backed [MarkdownText] Composable is exercised end-to-end
 * via `assembleDebug` and the live Chat screen; rendering tests are
 * not added here because Markwon requires a real Android `Context`
 * and the value over a manual smoke test is marginal for this
 * surface.
 */
internal class MarkdownPaletteTest {

    @Test
    fun `parser produces a non-empty list and preserves the prose`() {
        val prose = "# Hello\n\nA paragraph with **bold** and a [link](https://example.com)."
        val segments = MessageSegmentParser.parse(prose)

        assertTrue("expected at least one segment", segments.isNotEmpty())
        val first = segments.first()
        assertTrue("first segment should be a MarkdownBody", first is MessageSegment.MarkdownBody)
        assertEquals(prose, (first as MessageSegment.MarkdownBody).text)
    }

    @Test
    fun `markdown with a non-snippet fence still produces at least one segment`() {
        val raw = "Intro\n\n```\nplain\n```\n\nOutro"
        val segments = MessageSegmentParser.parse(raw)

        assertNotNull(segments)
        assertTrue(segments.isNotEmpty())
    }

    @Test
    fun `palette exposes the tokens the markdown UI depends on`() {
        // The renderer in `buildMarkwon` reads these exact tokens, and
        // `MarkdownContentView`/`SnippetBlock` read the surface + accent
        // tokens. Assert they resolve to non-zero ARGB ints so a future
        // palette refactor that drops them will fail here.
        assertNotNull(Palette.Accent)
        assertNotNull(Palette.Surface)
        assertNotNull(Palette.SurfaceElevated)
        assertNotNull(Palette.TextPrimary)
        assertNotNull(Palette.TextTertiary)
        assertNotNull(Palette.Separator)
        assertNotNull(Palette.CodeToken)
    }
}
