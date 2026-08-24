package app.roamsocket.android.ui.browser

import app.roamsocket.android.ui.browser.BrowserStep
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Lightweight contract tests for [BrowserAgent]'s JSON shape — the same
 * regression coverage the iOS `BrowserAgentTests` carries. We don't
 * hit a real provider here; we just exercise the parser so the wire
 * contract is locked down.
 */
class BrowserAgentTest {

    @Test fun `parses well-formed plan`() {
        val raw = """
            {"goal":"Search for cats","steps":[
              {"kind":"navigate","target":"https://google.com","value":null,"description":"Open Google"},
              {"kind":"type","target":"search box","value":"cats","description":"Type 'cats'"},
              {"kind":"click","target":"search button","value":null,"description":"Click search"},
              {"kind":"extract","target":null,"value":null,"description":"Summarize results"}
            ]}
        """.trimIndent()
        val plan = BrowserAgent.parsePlan(raw)
        assertEquals("Search for cats", plan.goal)
        assertEquals(4, plan.steps.size)
        assertEquals(BrowserStep.Kind.NAVIGATE, plan.steps[0].kind)
        assertEquals("https://google.com", plan.steps[0].target)
        assertEquals(BrowserStep.Kind.TYPE, plan.steps[1].kind)
        assertEquals("cats", plan.steps[1].value)
        assertEquals(BrowserStep.Kind.CLICK, plan.steps[2].kind)
        assertEquals(BrowserStep.Kind.EXTRACT, plan.steps[3].kind)
    }

    @Test fun `parses plan wrapped in code fence`() {
        val raw = """
            ```json
            {"goal":"Find flights","steps":[
              {"kind":"navigate","target":"https://example.com","description":"Go to example"}
            ]}
            ```
        """.trimIndent()
        val plan = BrowserAgent.parsePlan(raw)
        assertEquals("Find flights", plan.goal)
        assertEquals(1, plan.steps.size)
    }

    @Test fun `rejects plan with no valid steps`() {
        val raw = """{"goal":"Empty","steps":[]}"""
        try {
            BrowserAgent.parsePlan(raw)
            fail("expected PlanError.Decoding")
        } catch (e: BrowserAgent.PlanError.Decoding) {
            assertNotNull(e.message)
        }
    }

    @Test fun `drops steps with unknown kinds`() {
        val raw = """
            {"goal":"Mixed","steps":[
              {"kind":"navigate","target":"https://x","description":"valid"},
              {"kind":"levitate","target":"moon","description":"unknown kind"},
              {"kind":"click","target":"button","description":"also valid"}
            ]}
        """.trimIndent()
        val plan = BrowserAgent.parsePlan(raw)
        // The two valid steps are kept; the unknown kind is silently dropped.
        assertEquals(2, plan.steps.size)
        assertEquals(BrowserStep.Kind.NAVIGATE, plan.steps[0].kind)
        assertEquals(BrowserStep.Kind.CLICK, plan.steps[1].kind)
    }

    @Test fun `consent-page heuristic flags obvious banner copy`() {
        assertTrue(BrowserAgent.looksLikeConsentPage("We use cookies. By clicking accept all, you agree to our privacy choices."))
        assertTrue(BrowserAgent.looksLikeConsentPage("Cookie preferences. Manage settings to personalize my choices."))
    }

    @Test fun `consent-page heuristic does not flag normal prose`() {
        // A single mention of "cookies" in a privacy policy is not a
        // consent banner — the heuristic needs >= 2 marker hits.
        assertEquals(false, BrowserAgent.looksLikeConsentPage("This page explains how to bake cookies at home."))
        assertEquals(false, BrowserAgent.looksLikeConsentPage(""))
    }
}
