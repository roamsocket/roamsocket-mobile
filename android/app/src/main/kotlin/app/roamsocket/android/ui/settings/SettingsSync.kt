package app.roamsocket.android.ui.settings

import android.util.Base64
import app.roamsocket.core.providers.HTTPClient
import app.roamsocket.core.providers.HTTPResponse
import app.roamsocket.core.providers.ProviderError
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

/**
 * Talks to GitHub's REST API to push/pull the user's settings snapshot
 * to a private repo (`roamsocket-mobile-settings`, auto-created on
 * first push). Mirrors the iOS `SettingsSync` shape but uses the
 * existing `OkHttpHTTPClient` already in the `AppContainer`.
 *
 * Endpoints used (all `https://api.github.com`):
 *
 *  - `GET  /user`                                  → resolve login
 *  - `GET  /repos/{owner}/{repo}`                  → check if repo exists
 *  - `POST /user/repos`                            → create a private repo
 *  - `GET  /repos/{owner}/{repo}/contents/{path}`  → fetch a file (incl. base64)
 *  - `PUT  /repos/{owner}/{repo}/contents/{path}`  → upsert a file
 */
class SettingsSync(
    private val httpClient: HTTPClient,
    private val baseUrl: String = "https://api.github.com",
) {

    sealed class SyncError(message: String) : RuntimeException(message) {
        class NoToken : SyncError("Link a GitHub PAT in Settings → Account first.")
        class RepoNotFound(repoFullName: String) :
            SyncError("Repo $repoFullName not found. Tap Sync to create it.")
        class HttpStatus(status: Int, body: String) :
            SyncError("GitHub $status: ${body.take(200)}")
        class Transport(message: String) : SyncError("Network error: $message")
    }

    data class RepoMeta(val fullName: String, val defaultBranch: String)

    /**
     * Resolve the sync repo. Creates it on first call. The repo is
     * always private and named [SettingsSyncSnapshot.REPO_NAME].
     */
    suspend fun ensureRepo(token: String): RepoMeta = withContext(Dispatchers.IO) {
        require(token.isNotBlank()) { throw SyncError.NoToken() }
        val user = fetchUser(token)
        val fullName = "${user.login}/${SettingsSyncSnapshot.REPO_NAME}"
        if (repoExists(token, fullName)) {
            val branch = fetchRepoDefaultBranch(token, fullName)
            RepoMeta(fullName, branch)
        } else {
            createRepo(token, user.login)
        }
    }

    /**
     * Push [snapshot] to the user's repo. Creates the file on the
     * first call; updates in place thereafter (the file path +
     * message are the only diffs).
     */
    suspend fun push(token: String, repo: RepoMeta, snapshot: SettingsSyncSnapshot): Unit =
        withContext(Dispatchers.IO) {
            require(token.isNotBlank()) { throw SyncError.NoToken() }
            val path = SettingsSyncSnapshot.FILE_PATH
            val content = Json.encodeToString(SettingsSyncSnapshot.serializer(), snapshot)
            val encoded = Base64.encodeToString(content.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            val existingSha = if (fileExists(token, repo.fullName, path)) {
                fetchFileSha(token, repo.fullName, path)
            } else null
            val body = JSONObject().apply {
                put("message", "Sync RoamSocket settings")
                put("content", encoded)
                if (existingSha != null) put("sha", existingSha)
            }
            val response = exec(
                method = "PUT",
                path = "/repos/${repo.fullName}/contents/$path",
                token = token,
                body = body.toString(),
            )
            // The PUT returns 200 (update) or 201 (create). Both are success.
            if (response.status !in 200..299) {
                throw SyncError.HttpStatus(response.status, response.body)
            }
        }

    /**
     * Pull the snapshot from the user's repo. Returns null when the
     * file doesn't exist yet (first run, fresh repo).
     */
    suspend fun pull(token: String, repo: RepoMeta): SettingsSyncSnapshot? =
        withContext(Dispatchers.IO) {
            require(token.isNotBlank()) { throw SyncError.NoToken() }
            val path = SettingsSyncSnapshot.FILE_PATH
            if (!fileExists(token, repo.fullName, path)) return@withContext null
            val response = exec(
                method = "GET",
                path = "/repos/${repo.fullName}/contents/$path",
                token = token,
            )
            if (response.status == 404) return@withContext null
            if (!response.isSuccessful) {
                throw SyncError.HttpStatus(response.status, response.body)
            }
            val payload = JSONObject(response.body)
            val encoded = payload.optString("content").orEmpty()
            // GitHub's content endpoint returns base64 with embedded newlines
            // for legacy content. Strip them before decoding.
            val cleaned = encoded.replace("\n", "").replace("\r", "")
            val bytes = runCatching { Base64.decode(cleaned, Base64.DEFAULT) }
                .getOrElse { throw SyncError.HttpStatus(500, "base64 decode: ${it.message}") }
            val text = String(bytes, Charsets.UTF_8)
            runCatching { Json.decodeFromString(SettingsSyncSnapshot.serializer(), text) }
                .getOrElse { throw SyncError.HttpStatus(500, "json decode: ${it.message}") }
        }

    // --- GitHub primitives ---

    private data class User(val login: String)

    private suspend fun fetchUser(token: String): User {
        val response = exec("GET", "/user", token)
        if (!response.isSuccessful) {
            throw SyncError.HttpStatus(response.status, response.body)
        }
        val login = JSONObject(response.body).optString("login").orEmpty()
        if (login.isBlank()) throw SyncError.HttpStatus(500, "no login in /user response")
        return User(login)
    }

    private suspend fun repoExists(token: String, fullName: String): Boolean {
        val response = exec("GET", "/repos/$fullName", token)
        return when (response.status) {
            200 -> true
            404 -> false
            else -> throw SyncError.HttpStatus(response.status, response.body)
        }
    }

    private suspend fun fetchRepoDefaultBranch(token: String, fullName: String): String {
        val response = exec("GET", "/repos/$fullName", token)
        if (!response.isSuccessful) {
            throw SyncError.HttpStatus(response.status, response.body)
        }
        return JSONObject(response.body).optString("default_branch").ifBlank { "main" }
    }

    private suspend fun createRepo(token: String, owner: String): RepoMeta {
        val body = JSONObject().apply {
            put("name", SettingsSyncSnapshot.REPO_NAME)
            put("description", "Synced RoamSocket Android settings (auto-created).")
            put("private", true)
            put("auto_init", true)
        }
        val response = exec("POST", "/user/repos", token, body.toString())
        if (response.status !in 200..299) {
            throw SyncError.HttpStatus(response.status, response.body)
        }
        val obj = JSONObject(response.body)
        val fullName = obj.optString("full_name").ifBlank { "$owner/${SettingsSyncSnapshot.REPO_NAME}" }
        val branch = obj.optString("default_branch").ifBlank { "main" }
        return RepoMeta(fullName, branch)
    }

    private suspend fun fileExists(token: String, fullName: String, path: String): Boolean {
        val response = exec("GET", "/repos/$fullName/contents/$path", token)
        return when (response.status) {
            200 -> true
            404 -> false
            else -> throw SyncError.HttpStatus(response.status, response.body)
        }
    }

    private suspend fun fetchFileSha(token: String, fullName: String, path: String): String? {
        val response = exec("GET", "/repos/$fullName/contents/$path", token)
        if (!response.isSuccessful) return null
        return runCatching { JSONObject(response.body).optString("sha") }.getOrNull()?.ifBlank { null }
    }

    /**
     * Wrap an `HTTPClient.data` call with proper auth + JSON headers.
     * We don't go through [ProviderError] on purpose — GitHub error
     * semantics don't map 1:1 to provider errors. We re-throw our own
     * [SyncError] so the ViewModel can show a human-readable message.
     */
    private suspend fun exec(
        method: String,
        path: String,
        token: String,
        body: String? = null,
    ): HTTPResponse = try {
        val url = baseUrl.trimEnd('/') + path
        val requestBody = body?.toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url(url)
            .method(method, requestBody)
            .headers(
                Headers.headersOf(
                    "Accept", "application/vnd.github+json",
                    "Authorization", "Bearer $token",
                    "X-GitHub-Api-Version", "2022-11-28",
                    "User-Agent", "RoamSocket-Android",
                ),
            )
            .build()
        httpClient.data(request)
    } catch (e: ProviderError) {
        throw SyncError.HttpStatus(0, e.message ?: e.javaClass.simpleName)
    } catch (e: SyncError) {
        throw e
    } catch (e: Exception) {
        throw SyncError.Transport(e.message ?: e.javaClass.simpleName)
    }

    private val HTTPResponse.isSuccessful: Boolean
        get() = status in 200..299
}
