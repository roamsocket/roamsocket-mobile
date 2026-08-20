package app.roamsocket.core.github

import app.roamsocket.core.providers.HTTPClient
import app.roamsocket.core.providers.HTTPResponse
import okhttp3.Headers
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GitHubClientTest {

    private class FakeHTTP(private val response: HTTPResponse) : HTTPClient {
        var lastRequest: Request? = null
        override suspend fun data(request: Request): HTTPResponse {
            lastRequest = request
            return response
        }
    }

    @Test
    fun `listRepos parses GitHub user repos payload`() {
        val body = """
            [
              {
                "full_name": "acme/widgets",
                "name": "widgets",
                "owner": {"login": "acme", "avatar_url": "https://x/a.png"},
                "private": false,
                "default_branch": "main",
                "pushed_at": "2026-01-02T03:04:05Z"
              },
              {
                "full_name": "acme/private",
                "name": "private",
                "owner": {"login": "acme"},
                "private": true,
                "default_branch": "trunk"
              }
            ]
        """.trimIndent()
        val http = FakeHTTP(HTTPResponse(200, body, Headers.headersOf()))
        val client = GitHubClient(http = http)

        val repos: List<GitHubRepo> = runCatching {
            kotlinx.coroutines.runBlocking { client.listRepos(token = "ghp_test") }
        }.getOrElse { error("decode failed: $it") }

        assertEquals(2, repos.size)
        assertEquals("acme/widgets", repos[0].fullName)
        assertEquals("main", repos[0].defaultBranch)
        assertEquals(false, repos[0].isPrivate)
        assertEquals("acme/private", repos[1].fullName)
        assertEquals(true, repos[1].isPrivate)
        assertTrue("Authorization header must be Bearer", "Bearer ghp_test" ==
            http.lastRequest?.header("Authorization"))
    }

    @Test
    fun `getRepo decodes a single repo`() {
        val body = """
            {
              "full_name": "octocat/Hello-World",
              "name": "Hello-World",
              "owner": {"login": "octocat"},
              "private": false,
              "default_branch": "master"
            }
        """.trimIndent()
        val http = FakeHTTP(HTTPResponse(200, body, Headers.headersOf()))
        val client = GitHubClient(http = http)

        val repo: GitHubRepo = runCatching {
            kotlinx.coroutines.runBlocking { client.getRepo(token = "ghp_test", fullName = "octocat/Hello-World") }
        }.getOrElse { error("decode failed: $it") }

        assertEquals("octocat/Hello-World", repo.fullName)
        assertEquals("master", repo.defaultBranch)
    }
}
