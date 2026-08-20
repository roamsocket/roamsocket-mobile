package app.roamsocket.android.ui.repositories

import app.roamsocket.core.github.GitHubOwner
import app.roamsocket.core.github.GitHubRepo
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-JVM unit test for the picker filter logic. Stays in
 * `app` (not `RoamSocketCore`) because the query state lives in the
 * Android view-model.
 */
class RepositoryPickerFilterTest {

    private val repos = listOf(
        GitHubRepo(
            fullName = "roamsocket/mobile",
            name = "mobile",
            owner = GitHubOwner(login = "roamsocket"),
            isPrivate = false,
            defaultBranch = "main",
        ),
        GitHubRepo(
            fullName = "roamsocket/desktop-server",
            name = "desktop-server",
            owner = GitHubOwner(login = "roamsocket"),
            isPrivate = true,
            defaultBranch = "main",
        ),
        GitHubRepo(
            fullName = "acme/widgets",
            name = "widgets",
            owner = GitHubOwner(login = "acme"),
            isPrivate = false,
            defaultBranch = "main",
        ),
    )

    @Test
    fun emptyQueryReturnsAll() {
        val result = repos.filter { it.fullName.contains("", ignoreCase = true) }
        assertEquals(repos.size, result.size)
    }

    @Test
    fun substringMatchIsCaseInsensitive() {
        val result = repos.filter { it.fullName.contains("ROAM", ignoreCase = true) }
        assertEquals(2, result.size)
    }

    @Test
    fun nonMatchingQueryReturnsEmpty() {
        val result = repos.filter { it.fullName.contains("zzz", ignoreCase = true) }
        assertEquals(0, result.size)
    }
}
