/*
 * Connects the app to the desktop coding server: HTTP pairing to obtain a
 * bearer token, then a WebSocket carrying the agent protocol. Inbound
 * frames are exposed as a `Flow<ServerMessage>`. Mirrors
 * `ios/AnyProvCore/.../Server/ServerClient.swift`.
 */
package app.roamsocket.core.server

import app.roamsocket.core.protocol.ClientMessage
import app.roamsocket.core.protocol.PairRequest
import app.roamsocket.core.protocol.PairResponse
import app.roamsocket.core.protocol.ServerMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * A desktop server the app can talk to. Created either manually (typed
 * host:port) or from NSD discovery.
 */
public data class Endpoint(
    /** Origin used for pairing + WebSocket. Always has a scheme + port. */
    val baseURL: String,
) {
    public companion object {
        public const val DEFAULT_PORT: Int = 4319

        /**
         * Parse a user-typed "host" or "host:port" into an [Endpoint].
         * Accepts bare IPs, hostnames, `http://` / `https://` URLs. Defaults
         * the port to 4319 when omitted.
         */
        public fun fromHost(raw: String): Endpoint? {
            val trimmed = raw.trim()
            if (trimmed.isEmpty()) return null
            val withScheme = if (!trimmed.contains("://")) "http://$trimmed" else trimmed
            val normalized = withScheme.trimEnd('/')
            val schemeEnd = normalized.indexOf("://")
            val afterScheme = normalized.substring(schemeEnd + 3)
            val slash = afterScheme.indexOf('/')
            val hostPort = if (slash >= 0) afterScheme.substring(0, slash) else afterScheme
            if (hostPort.isEmpty()) return null
            val (host, port) = parseHostPort(hostPort)
                ?: return null
            val finalPort = port ?: DEFAULT_PORT
            val scheme = normalized.substring(0, schemeEnd).lowercase()
            val wsScheme = if (scheme == "https") "https" else "http"
            return Endpoint(baseURL = "$wsScheme://$host:$finalPort")
        }

        private fun parseHostPort(hostPort: String): Pair<String, Int?>? {
            // IPv6 literal in brackets.
            if (hostPort.startsWith("[")) {
                val close = hostPort.indexOf(']')
                if (close < 0) return null
                val host = hostPort.substring(1, close)
                val rest = hostPort.substring(close + 1)
                val port = if (rest.startsWith(":")) rest.substring(1).toIntOrNull() else null
                return host to port
            }
            val colon = hostPort.lastIndexOf(':')
            return if (colon > 0 && hostPort.substring(colon + 1).toIntOrNull() != null) {
                hostPort.substring(0, colon) to hostPort.substring(colon + 1).toInt()
            } else {
                hostPort to null
            }
        }
    }
}

public class ServerClient(
    private val httpClient: OkHttpClient = defaultHttpClient(),
    private val wsClient: OkHttpClient = defaultHttpClient(pingIntervalSec = 20),
) {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val jsonMedia = "application/json".toMediaType()

    /**
     * Exchange a pairing code for a bearer token. The HTTP server logs
     * the 6-digit code on its console; the user types it into the app.
     */
    public suspend fun pair(endpoint: Endpoint, code: String, deviceName: String): PairResponse {
        val body = json.encodeToString(
            PairRequest.serializer(),
            PairRequest(code = code, deviceName = deviceName),
        )
        val req = Request.Builder()
            .url("${endpoint.baseURL}/pair")
            .post(body.toRequestBody(jsonMedia))
            .build()
        return withContext(Dispatchers.IO) {
            try {
                httpClient.newCall(req).execute().use(::parsePairResponse)
            } catch (e: IOException) {
                throw ServerClientException.PairFailed(e.message ?: e.javaClass.simpleName)
            }
        }
    }

    private fun parsePairResponse(response: Response): PairResponse {
        val body = response.body?.string().orEmpty()
        if (!response.isSuccessful) {
            throw ServerClientException.PairFailed("HTTP ${response.code}: $body")
        }
        return try {
            json.decodeFromString(PairResponse.serializer(), body)
        } catch (e: Exception) {
            throw ServerClientException.PairFailed("Bad response: ${e.message}")
        }
    }

    /**
     * Open the session WebSocket and yield decoded [ServerMessage]s as a
     * hot Flow. Closes when the socket drops; the caller is expected to
     * re-collect after handling.
     */
    public fun connect(
        endpoint: Endpoint,
        token: String,
        scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    ): Session {
        val outgoing = MutableSharedFlow<ClientMessage>(
            extraBufferCapacity = 64,
            onBufferOverflow = BufferOverflow.SUSPEND,
        )
        val incoming = MutableSharedFlow<ServerMessage>(
            extraBufferCapacity = 256,
            onBufferOverflow = BufferOverflow.DROP_OLDEST,
        )
        val wsUrl = "${endpoint.baseURL.replaceFirst("http", "ws")}/session?token=$token"
        val request = Request.Builder().url(wsUrl).build()

        var webSocket: WebSocket? = null
        val closeSignal = MutableSharedFlow<Unit>(replay = 0, extraBufferCapacity = 1)

        val job: Job = scope.launch {
            val socket = wsClient.newWebSocket(request, object : WebSocketListener() {
                override fun onMessage(webSocket: WebSocket, text: String) {
                    val msg = runCatching {
                        json.decodeFromString(ServerMessage.serializer(), text)
                    }.getOrNull() ?: return
                    incoming.tryEmit(msg)
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    // Server never sends binary frames; ignore.
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    closeSignal.tryEmit(Unit)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    closeSignal.tryEmit(Unit)
                }
            })
            webSocket = socket
            // Wait for the socket to close; nothing else to do.
            closeSignal.asSharedFlow().let { /* keep collector alive */ }
        }

        return Session(
            incoming = incoming.asSharedFlow(),
            send = { msg ->
                val text = json.encodeToString(ClientMessage.serializer(), msg)
                val ok = webSocket?.send(text) ?: false
                if (!ok) error("WebSocket not connected")
            },
            close = {
                runCatching { webSocket?.close(1000, "client close") }
                scope.cancel()
            },
        )
    }

    public companion object {
        public const val DEFAULT_PORT: Int = Endpoint.DEFAULT_PORT

        public fun defaultHttpClient(pingIntervalSec: Long = 0): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS)
            .callTimeout(180, TimeUnit.SECONDS)
            .pingInterval(if (pingIntervalSec > 0) pingIntervalSec else 0, TimeUnit.SECONDS)
            .build()
    }
}

/** Active session over a connected [ServerClient]. */
public class Session internal constructor(
    public val incoming: Flow<ServerMessage>,
    private val send: (ClientMessage) -> Unit,
    private val close: () -> Unit,
) {
    public fun send(message: ClientMessage): Unit = send(message)
    public fun close(): Unit = close()
}

/** Errors raised by [ServerClient]. */
public sealed class ServerClientException(message: String) : RuntimeException(message) {
    public object BadURL : ServerClientException("Invalid server address.")
    public data class PairFailed(public val detail: String) :
        ServerClientException("Pairing failed: $detail")
    public data class ConnectFailed(public val detail: String) : ServerClientException(detail)
    public data class SendFailed(public val detail: String) : ServerClientException(detail)
    public data class HttpFailed(public val detail: String) : ServerClientException(detail)
}
