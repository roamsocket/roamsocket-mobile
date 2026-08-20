/*
 * GitHub client. PAT-based for now (the user pastes a Personal Access Token
 * in Settings); Device Flow + OAuth app client-id land in a follow-up
 * PR once the Settings UI has a place for them. Mirrors
 * `ios/AnyProvCore/.../GitHubClient.swift`.
 */
package app.roamsocket.core.github

import app.roamsocket.core.providers.HTTPClient
import app.roamsocket.core.providers.HTTPResponse
import app.roamsocket.core.providers.OkHttpHTTPClient
import app.roamsocket.core.providers.ProviderHTTP
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** A GitHub repository the user can pick for a session. */
@Serializable
public data class GitHubRepo(
    @SerialName("full_name") val fullName: String,
    val name: String,
    val owner: GitHubOwner,
    @SerialName("private") val isPrivate: Boolean,
    @SerialName("default_branch") val defaultBranch: String,
    @SerialName("pushed_at") val pushedAt: String? = null,
) {
    public val id: String get() = fullName
}

@Serializable
public data class GitHubOwner(
    val login: String,
    @SerialName("avatar_url") val avatarUrl: String? = null,
)

public sealed class GitHubError(message: String) : RuntimeException(message) {
    public data class Http(val status: Int, val body: String) :
        GitHubError("GitHub HTTP $status: ${body.take(200)}")
    public data class Decoding(val detail: String) :
        GitHubError("Failed to decode GitHub response: $detail")
}

/**
 * Minimal GitHub client: list repos, look up a single repo, get the
 * default branch. Authenticates with a Personal Access Token; the token
 * is sent in the `Authorization: Bearer …` header.
 */
public class GitHubClient(
    private val http: HTTPClient = OkHttpHTTPClient(),
    private val baseURL: String = "https://api.github.com",
) {

    private val json = Json { ignoreUnknownKeys = true }

    public suspend fun listRepos(token: String, perPage: Int = 50): List<GitHubRepo> {
        val response = http.data(
            request = ProviderHTTP.get(
                url = "$baseURL/user/repos?per_page=$perPage&sort=pushed&type=owner",
                headers = mapOf(
                    "Authorization" to "Bearer $token",
                    "Accept" to "application/vnd.github+json",
                    "X-GitHub-Api-Version" to "2022-11-28",
                ),
            ),
        )
        return parseList(response)
    }

    public suspend fun getRepo(token: String, fullName: String): GitHubRepo {
        val response = http.data(
            request = ProviderHTTP.get(
                url = "$baseURL/repos/$fullName",
                headers = mapOf(
                    "Authorization" to "Bearer $token",
                    "Accept" to "application/vnd.github+json",
                    "X-GitHub-Api-Version" to "2022-11-28",
                ),
            ),
        )
        return runCatching {
            json.decodeFromString(GitHubRepo.serializer(), response.body)
        }.getOrElse { throw GitHubError.Decoding(it.message ?: it.javaClass.simpleName) }
    }

    private fun parseList(response: HTTPResponse): List<GitHubRepo> = runCatching {
        json.decodeFromString(ListSerializer(GitHubRepo.serializer()), response.body)
    }.getOrElse { throw GitHubError.Decoding(it.message ?: it.javaClass.simpleName) }
}
