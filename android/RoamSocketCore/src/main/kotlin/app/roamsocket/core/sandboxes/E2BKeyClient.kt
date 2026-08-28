/*
 * E2B key wire client. Mirrors the iOS
 * `ios/AnyProvCore/.../Sync/E2BKeyClient.swift` (the one that ships
 * with PR #106).
 *
 * Each call opens a short-lived WebSocket, sends `e2b_set_key`, waits
 * for the matching `e2b_key_ack` (or an `error`), then disconnects.
 * The desktop stores the override in memory against the bearer
 * token only, so re-pairing clears it.
 */
package app.roamsocket.core.sandboxes

import app.roamsocket.core.protocol.ClientMessage
import app.roamsocket.core.protocol.ServerMessage
import app.roamsocket.core.server.Endpoint
import app.roamsocket.core.server.ServerClient
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/** Errors raised by the E2B key round trip. */
public sealed class E2BKeyError(message: String) : RuntimeException(message) {
    public data object NoServer : E2BKeyError("Not paired with a desktop server.")
    public data class ServerError(public val detail: String) :
        E2BKeyError(detail.ifEmpty { "Desktop rejected the E2B key change." })
    public data object Timeout : E2BKeyError("Desktop did not acknowledge the E2B key change.")
}

/** Result of an `e2b_set_key` round trip — mirrors the desktop's
 *  `e2b_key_ack` payload. */
public data class E2BKeyResult(
    val overrideActive: Boolean,
)

public class E2BKeyClient(
    private val serverClient: ServerClient = ServerClient(),
) {
    public suspend fun setKey(
        apiKey: String,
        endpoint: Endpoint,
        token: String,
        timeoutSeconds: Long = 10,
    ): E2BKeyResult {
        val session = serverClient.connect(endpoint = endpoint, token = token)
        try {
            session.send(ClientMessage.E2bSetKey(apiKey = apiKey))
            val deadline = System.currentTimeMillis() + timeoutSeconds * 1000
            while (true) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) throw E2BKeyError.Timeout
                val next = withTimeoutOrNull(remaining) {
                    session.incoming.first()
                } ?: throw E2BKeyError.Timeout
                when (next) {
                    is ServerMessage.E2bKeyAck -> {
                        return E2BKeyResult(overrideActive = next.overrideActive)
                    }
                    is ServerMessage.Error -> {
                        throw E2BKeyError.ServerError(next.message)
                    }
                    else -> continue
                }
            }
            @Suppress("UNREACHABLE_CODE")
            error("unreachable")
        } catch (e: E2BKeyError) {
            throw e
        } catch (e: TimeoutCancellationException) {
            throw E2BKeyError.Timeout
        } catch (e: Exception) {
            throw E2BKeyError.ServerError(e.message ?: e.javaClass.simpleName)
        } finally {
            runCatching { session.close() }
        }
    }
}
