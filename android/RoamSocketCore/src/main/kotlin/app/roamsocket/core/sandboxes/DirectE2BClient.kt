/*
 * E2B.dev direct (phone-originated) sandbox client. Mirrors
 * `ios/AnyProvCore/.../Sandboxes/DirectE2BClient.swift`.
 *
 * Used by the Sandboxes screen when the phone wants to spin up a
 * sandbox without a paired desktop. The flow:
 *   1. POST /sandboxes (with X-API-Key) to create a sandbox using the
 *      code-interpreter template.
 *   2. POST a Python shim to the sandbox's `/execute` endpoint. The
 *      shim clones the requested repo, checks out the branch, then
 *      runs the user's command under subprocess.Popen so each stdout
 *      / stderr line can stream back as an NDJSON event.
 *   3. Parse the NDJSON stream (`STDOUT:`, `STDERR:`, `EXIT:`) and
 *      fold the events into the run lifecycle.
 *   4. DELETE /sandboxes/{id} on completion to free the VM.
 *
 * The official e2b JS/Python SDKs use envd Connect-RPC, which would
 * require protobuf plumbing in Kotlin. Routing through the simpler
 * code-interpreter template keeps the implementation HTTP-only.
 */
package app.roamsocket.core.sandboxes

import app.roamsocket.core.providers.HTTPClient
import app.roamsocket.core.providers.OkHttpHTTPClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException

/** A single phone-originated E2B run. Mirrors the desktop
 *  `E2bRunPayload` shape so the Sandboxes view can show both kinds
 *  in the same list and mark phone runs with a `PHONE` badge. */
@Serializable
public data class E2bPhoneRun(
    val id: String,
    val source: String = "phone",
    val repoFullName: String,
    val branch: String,
    val command: String,
    val status: String,
    val exitCode: Int? = null,
    val sandboxId: String? = null,
    val sandboxUrl: String? = null,
    val startedAt: Long? = null,
    val finishedAt: Long? = null,
    val outputTail: List<String> = emptyList(),
    val error: String? = null,
)

/** Where the run's source repository lives. */
public enum class E2bPhoneRepoSource { github, url }

/** A repo selection — either a GitHub `owner/name` or a raw URL. */
public sealed class E2bPhoneRepoSelection {
    public data class Github(val fullName: String) : E2bPhoneRepoSelection()
    public data class Url(val url: String) : E2bPhoneRepoSelection()

    public fun displayName(): String = when (this) {
        is Github -> fullName
        is Url -> url
    }
}

/** Request the phone sends to start a new E2B run. */
public data class E2bPhoneRunRequest(
    val repo: E2bPhoneRepoSelection,
    val branch: String,
    val command: String,
    val githubToken: String? = null,
)

/** Events streamed from a live E2B sandbox run. */
public sealed class E2bPhoneRunEvent {
    public data class Log(val stream: String, val line: String) : E2bPhoneRunEvent()
    public data class Finished(val exitCode: Int?) : E2bPhoneRunEvent()
    public data class Failed(val message: String) : E2bPhoneRunEvent()
}

public sealed class DirectE2BError(message: String) : RuntimeException(message) {
    public data object NoApiKey : DirectE2BError("Add your e2b.dev API key in Settings first.")
    public data class Http(val status: Int, val body: String) :
        DirectE2BError("E2B HTTP $status: ${body.take(160)}")
    public data class Stream(val detail: String) : DirectE2BError("E2B stream: $detail")
    public data class Transport(val detail: String) : DirectE2BError("E2B transport: $detail")
    public data class Decoding(val detail: String) :
        DirectE2BError("E2B decode: $detail")
}

/** Metadata returned by `POST /sandboxes`. */
public data class E2bSandboxInfo(
    val sandboxId: String,
    val accessToken: String?,
    val domain: String,
    val template: String,
)

/** Out-of-session client for the E2B.dev HTTP API. */
public class DirectE2BClient(
    private val apiKey: String,
    private val http: HTTPClient = OkHttpHTTPClient(),
    private val baseURL: String = "https://api.e2b.dev",
    private val codeInterpreterPort: Int = 49999,
    private val codeInterpreterTemplate: String = "code-interpreter-beta",
    private val okHttp: OkHttpClient = OkHttpClient(),
) {

    private val json = Json { ignoreUnknownKeys = true }

    /** Create a fresh sandbox. The access token comes back in the
     *  `X-Access-Token` response header (when the sandbox is
     *  secured) and is needed for follow-up calls into the sandbox
     *  itself. */
    public suspend fun createSandbox(timeoutMs: Int = 600_000): E2bSandboxInfo {
        val trimmed = apiKey.trim()
        require(trimmed.isNotEmpty()) { throw DirectE2BError.NoApiKey }

        val body = """{"templateID":"$codeInterpreterTemplate","timeout":$timeoutMs}"""
        val request = Request.Builder()
            .url("$baseURL/sandboxes")
            .post(body.toRequestBody("application/json".toMediaType()))
            .header("X-API-Key", trimmed)
            .header("Content-Type", "application/json")
            .header("User-Agent", "anyprov-code")
            .build()
        val response = http.data(request)
        if (response.status !in 200..299) {
            throw DirectE2BError.Http(response.status, response.body)
        }
        val parsed = json.parseToJsonElement(response.body).jsonObject
        val sandboxId = parsed["sandboxID"]?.jsonPrimitive?.content
            ?: throw DirectE2BError.Decoding("sandboxID missing from create response")
        val access = response.headers["X-Access-Token"]
        return E2bSandboxInfo(
            sandboxId = sandboxId,
            accessToken = access,
            domain = "e2b.dev",
            template = codeInterpreterTemplate,
        )
    }

    /** Best-effort kill. Errors are swallowed because the sandbox may
     *  have already timed out. */
    public suspend fun killSandbox(sandboxId: String) {
        val trimmed = apiKey.trim()
        if (trimmed.isEmpty()) return
        val request = Request.Builder()
            .url("$baseURL/sandboxes/$sandboxId")
            .delete()
            .header("X-API-Key", trimmed)
            .header("User-Agent", "anyprov-code")
            .build()
        runCatching { http.data(request) }
    }

    /** Stream `/execute` from a code-interpreter sandbox as a Flow
     *  of `E2bPhoneRunEvent`s. The shim's Python prints each stdout
     *  / stderr line as `STDOUT:line` / `STDERR:line`, then a final
     *  `EXIT:code` line. The flow completes when the stream ends. */
    public fun executeScript(
        sandboxId: String,
        accessToken: String?,
        script: String,
    ): Flow<E2bPhoneRunEvent> = callbackFlow {
        val url = "https://$codeInterpreterPort-$sandboxId.e2b.dev/execute"
        val body = """{"code":${jsonStringEscape(script)}}"""
        val request = Request.Builder()
            .url(url)
            .post(body.toRequestBody("application/json".toMediaType()))
            .header("Content-Type", "application/json")
            .header("User-Agent", "anyprov-code")
            .apply {
                if (accessToken != null) header("X-Access-Token", accessToken)
            }
            .build()
        val call = okHttp.newCall(request)
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                trySend(E2bPhoneRunEvent.Failed(e.message ?: "execute failed"))
                close()
            }
            override fun onResponse(call: Call, response: Response) {
                if (!response.isSuccessful) {
                    trySend(E2bPhoneRunEvent.Failed("execute HTTP ${response.code}"))
                    response.close()
                    close()
                    return
                }
                val source = response.body?.source() ?: run {
                    trySend(E2bPhoneRunEvent.Failed("empty execute body"))
                    response.close()
                    close()
                    return
                }
                try {
                    while (!source.exhausted()) {
                        val line = source.readUtf8Line() ?: break
                        val parsed = parseShimLine(line)
                        if (parsed != null) trySend(parsed)
                    }
                } catch (e: Exception) {
                    trySend(E2bPhoneRunEvent.Failed(e.message ?: "stream error"))
                } finally {
                    response.close()
                    close()
                }
            }
        })
        awaitClose { call.cancel() }
    }.flowOn(Dispatchers.IO)

    /** Build the Python shim that clones `repo`, checks out `branch`,
     *  then runs `command` with live streaming. Output is tagged so
     *  the client can recover stdout / stderr / exit. */
    public fun buildShimScript(
        repo: E2bPhoneRepoSelection,
        branch: String,
        command: String,
        githubToken: String?,
    ): String {
        val cloneURL: String = when (repo) {
            is E2bPhoneRepoSelection.Github -> {
                if (!githubToken.isNullOrEmpty()) {
                    "https://oauth2:$githubToken@github.com/${repo.fullName}.git"
                } else {
                    "https://github.com/${repo.fullName}.git"
                }
            }
            is E2bPhoneRepoSelection.Url -> repo.url
        }
        val quotedBranch = pythonQuote(branch)
        val quotedURL = pythonQuote(cloneURL)
        val quotedCommand = pythonQuote(command)
        return """
        import subprocess, sys, os, shlex

        def emit(stream, line):
            sys.stdout.write(f"{stream.upper()}:{line}")
            if not line.endswith("\n"):
                sys.stdout.write("\n")
            sys.stdout.flush()

        clone_url = $quotedURL
        branch = $quotedBranch
        proc = subprocess.run(
            ["git", "clone", "--depth", "1", clone_url, "/code"],
            capture_output=True, text=True,
        )
        for line in proc.stdout.splitlines():
            emit("stdout", line)
        for line in proc.stderr.splitlines():
            emit("stderr", line)
        if proc.returncode != 0:
            emit("exit", f"clone-failed:{proc.returncode}")
            sys.exit(0)

        try:
            proc = subprocess.run(
                ["git", "fetch", "--depth", "1", "origin", branch],
                cwd="/code", capture_output=True, text=True,
            )
            for line in proc.stderr.splitlines():
                emit("stderr", line)
            subprocess.run(
                ["git", "checkout", branch],
                cwd="/code", check=True, capture_output=True, text=True,
            )
        except Exception as exc:
            emit("stderr", f"checkout failed: {exc}")
            emit("exit", "checkout-failed")
            sys.exit(0)

        try:
            proc = subprocess.Popen(
                $quotedCommand,
                shell=True,
                cwd="/code",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
        except Exception as exc:
            emit("stderr", f"launch failed: {exc}")
            emit("exit", "launch-failed")
            sys.exit(0)

        import threading
        def pump(stream, label):
            for line in stream:
                emit(label, line.rstrip("\n"))
            stream.close()
        t_out = threading.Thread(target=pump, args=(proc.stdout, "stdout"), daemon=True)
        t_err = threading.Thread(target=pump, args=(proc.stderr, "stderr"), daemon=True)
        t_out.start()
        t_err.start()
        proc.wait()
        t_out.join(timeout=2)
        t_err.join(timeout=2)
        emit("exit", str(proc.returncode))
        """.trimIndent()
    }

    /** Run a `request` end-to-end and return the final `E2bPhoneRun`.
     *  The supplied `onEvent` is called for every streamed event. */
    public suspend fun run(
        request: E2bPhoneRunRequest,
        onEvent: suspend (E2bPhoneRunEvent) -> Unit,
    ): E2bPhoneRun {
        var run = E2bPhoneRun(
            id = "r_phone_" + generateId(),
            repoFullName = request.repo.displayName(),
            branch = request.branch,
            command = request.command,
            status = "queued",
            startedAt = System.currentTimeMillis(),
        )
        onEvent(E2bPhoneRunEvent.Log("stdout", "Creating sandbox…"))

        val sandbox: E2bSandboxInfo = try {
            createSandbox()
        } catch (e: Throwable) {
            val failed = run.copy(
                status = "failed",
                error = e.message ?: "Sandbox creation failed.",
                finishedAt = System.currentTimeMillis(),
            )
            onEvent(E2bPhoneRunEvent.Failed(failed.error ?: "Failed."))
            return failed
        }
        run = run.copy(
            sandboxId = sandbox.sandboxId,
            sandboxUrl = "https://${sandbox.sandboxId}.${sandbox.domain}",
            status = "running",
        )
        onEvent(E2bPhoneRunEvent.Log("stdout", "Sandbox ready: ${sandbox.sandboxId}"))

        val script = buildShimScript(
            repo = request.repo,
            branch = request.branch,
            command = request.command,
            githubToken = request.githubToken,
        )

        var exitCode: Int? = null
        var streamError: String? = null
        try {
            executeScript(sandbox.sandboxId, sandbox.accessToken, script)
                .collect { event ->
                    if (event is E2bPhoneRunEvent.Finished) {
                        exitCode = event.exitCode
                    } else if (event is E2bPhoneRunEvent.Failed) {
                        streamError = event.message
                    }
                    onEvent(event)
                }
        } catch (e: Throwable) {
            streamError = e.message ?: e.javaClass.simpleName
        }

        // 3. Best-effort: kill the sandbox so we don't leave it running.
        killSandbox(sandbox.sandboxId)

        run = if (streamError != null) {
            run.copy(
                status = "failed",
                error = streamError,
                finishedAt = System.currentTimeMillis(),
            )
        } else if (exitCode != null) {
            run.copy(
                status = if (exitCode == 0) "completed" else "failed",
                exitCode = exitCode,
                finishedAt = System.currentTimeMillis(),
            )
        } else {
            run.copy(
                status = "failed",
                error = "Sandbox stream ended without an exit code.",
                finishedAt = System.currentTimeMillis(),
            )
        }
        if (run.status == "completed") {
            onEvent(E2bPhoneRunEvent.Finished(run.exitCode))
        } else {
            onEvent(E2bPhoneRunEvent.Failed(run.error ?: "Failed."))
        }
        return run
    }

    private fun parseShimLine(line: String): E2bPhoneRunEvent? {
        if (line.isEmpty()) return null
        val sep = line.indexOf(':')
        if (sep <= 0) return E2bPhoneRunEvent.Log("stdout", line)
        return when (line.substring(0, sep)) {
            "STDOUT" -> E2bPhoneRunEvent.Log("stdout", line.substring(sep + 1))
            "STDERR" -> E2bPhoneRunEvent.Log("stderr", line.substring(sep + 1))
            "EXIT" -> {
                val value = line.substring(sep + 1)
                when {
                    value.startsWith("clone-failed:") -> {
                        E2bPhoneRunEvent.Failed("git clone failed (exit ${value.removePrefix("clone-failed:")})")
                    }
                    value == "checkout-failed" -> E2bPhoneRunEvent.Failed("git checkout failed")
                    value == "launch-failed" -> E2bPhoneRunEvent.Failed("command launch failed")
                    else -> E2bPhoneRunEvent.Finished(value.toIntOrNull())
                }
            }
            else -> E2bPhoneRunEvent.Log("stdout", line)
        }
    }

    private fun generateId(): String =
        java.util.UUID.randomUUID().toString().take(8).lowercase()

    /** Minimal JSON string escape (covers \", \\, control chars, and
     *  non-ASCII). Sufficient for the Python script body. */
    private fun jsonStringEscape(value: String): String {
        val sb = StringBuilder(value.length + 8)
        sb.append('"')
        for (c in value) {
            when (c) {
                '\\' -> sb.append("\\\\")
                '"' -> sb.append("\\\"")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                else -> if (c.code < 0x20) {
                    sb.append("\\u%04x".format(c.code))
                } else {
                    sb.append(c)
                }
            }
        }
        sb.append('"')
        return sb.toString()
    }
}

/** Minimal shlex.quote replacement. Matches CPython: wrap in single
 *  quotes, escape any embedded single quotes by closing + escaping +
 *  reopening the string. */
internal fun pythonQuote(value: String): String {
    if (value.isEmpty()) return "''"
    val safe = ('a'..'z').toSet() + ('A'..'Z').toSet() + ('0'..'9').toSet() +
        setOf('_', '-', '.', '/', ':', '=', '@', '%', '+', ',')
    if (value.all { it in safe }) return value
    val escaped = value.replace("'", "'\"'\"'")
    return "'$escaped'"
}
