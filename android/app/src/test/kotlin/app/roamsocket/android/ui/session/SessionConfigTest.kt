package app.roamsocket.android.ui.session

import app.roamsocket.core.protocol.Effort
import app.roamsocket.core.protocol.RepoRef
import app.roamsocket.core.providers.ProviderId
import org.junit.Assert.assertEquals
import org.junit.Test

class SessionConfigTest {

    @Test
    fun `default session config defaults effort to high`() {
        val config = SessionConfig(
            repo = RepoRef(fullName = "acme/widgets", workBranch = "feat/x"),
            model = SessionModelSelection(
                provider = ProviderId.Anthropic,
                model = "claude-3-5-sonnet-20241022",
                apiKey = "sk-…",
            ),
        )
        assertEquals(Effort.HIGH, config.model.effort)
        assertEquals("acme/widgets", config.repo.fullName)
        assertEquals("feat/x", config.repo.workBranch)
    }
}
