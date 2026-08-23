/*
 * One short-lived WebSocket for a tools request (file list, ports,
 * tunnels, terminal). Separate from the agent session client so tools
 * never drop the agent stream. Mirrors the iOS `WorkspaceRPC`
 * (`ios/App/Sources/Features/Session/SessionToolsView.swift`).
 */
package app.roamsocket.core.server

import app.roamsocket.core.protocol.ServerMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Open a one-shot RPC channel: connect, [send] the request, drain the
 * stream until [match] returns non-null, then disconnect.
 *
 * Throws [WorkspaceRpcError.MissingPairing] when the supplied token is
 * blank, and [WorkspaceRpcError.Timeout] when [match] never returns a
 * result within [timeoutSeconds].
 */
public object WorkspaceRpc {
    public suspend fun <T> withConnection(
        endpoint: Endpoint,
        token: String,
        timeoutSeconds: Long = 20,
        send: suspend (Session) -> Unit,
        match: (ServerMessage) -> T?,
    ): T {
        if (token.isEmpty()) throw WorkspaceRpcError.MissingPairing
        val client = ServerClient()
        val session = client.connect(endpoint, token)
        var found: T? = null
        val stopCollect = StopCollect()
        try {
            send(session)
            val outcome = withTimeoutOrNull(timeoutSeconds * 1000L) {
                session.incoming.collect { msg ->
                    val value = match(msg)
                    if (value != null) {
                        found = value
                        throw stopCollect
                    }
                }
            }
            if (outcome == null && found == null) {
                throw WorkspaceRpcError.Timeout
            }
        } catch (_: TimeoutCancellationException) {
            throw WorkspaceRpcError.Timeout
        } catch (e: CancellationException) {
            if (e !== stopCollect) throw e
            // stopCollect → break out cleanly
        } finally {
            runCatching { session.close() }
        }
        @Suppress("UNCHECKED_CAST")
        return found as T
    }

    private class StopCollect : CancellationException("workspace rpc matched") {
        override fun fillInStackTrace(): Throwable = this
    }
}

public sealed class WorkspaceRpcError(message: String) : RuntimeException(message) {
    public object Timeout : WorkspaceRpcError("Desktop did not respond in time.")
    public object MissingPairing : WorkspaceRpcError("Pair a desktop server first.")
}
