/*
 * Skills / MCP wire client. Mirrors the iOS
 * `ios/AnyProvCore/.../Sync/SkillsMCPClient.swift`.
 *
 * The desktop owns the canonical state (skills + MCP repos on the
 * user's GitHub). This client sends upsert / delete / sync over the
 * WebSocket; each op opens its own short-lived connection, waits for
 * the desktop's acknowledging `skills_sync` / `mcp_sync`, then tears
 * down. The long-lived session WebSocket isn't usable for these ops
 * because it only exists inside a coding session.
 */
package app.roamsocket.core.skills

import app.roamsocket.core.protocol.ClientMessage
import app.roamsocket.core.protocol.MCPServer
import app.roamsocket.core.protocol.ServerMessage
import app.roamsocket.core.protocol.Skill
import app.roamsocket.core.server.Endpoint
import app.roamsocket.core.server.ServerClient
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json

/** Errors raised by skills/MCP sync. */
public sealed class SkillsMCPError(message: String) : RuntimeException(message) {
    public data object NoServer : SkillsMCPError("Not paired with a desktop server.")
    public data class ServerError(public val detail: String) :
        SkillsMCPError(detail.ifEmpty { "Desktop sync failed." })
    public data object DecodeFailure : SkillsMCPError("Server returned malformed data.")
    public data object Timeout : SkillsMCPError("Desktop did not acknowledge the request.")
}

public class SkillsMCPClient(
    private val serverClient: ServerClient = ServerClient(),
    private val json: Json = Json { ignoreUnknownKeys = true; encodeDefaults = true },
) {

    private val _lastSyncError = MutableSharedFlow<String?>(replay = 1, extraBufferCapacity = 1)

    /** Latest sync error, if any. Backed by a SharedFlow so observers
     *  can collect it like a StateFlow when the desktop reports a
     *  problem. */
    public val lastSyncError: Flow<String?> = _lastSyncError

    public suspend fun requestSkillsSync(endpoint: Endpoint, token: String) {
        performOp(
            request = ClientMessage.SkillsSyncRequest,
            kind = SyncKind.Skills,
            endpoint = endpoint,
            token = token,
        )
    }

    public suspend fun requestMCPSync(endpoint: Endpoint, token: String) {
        performOp(
            request = ClientMessage.MCPSyncRequest,
            kind = SyncKind.MCP,
            endpoint = endpoint,
            token = token,
        )
    }

    public suspend fun upsertSkill(skill: Skill, endpoint: Endpoint, token: String) {
        performOp(
            request = ClientMessage.SkillUpsert(skill),
            kind = SyncKind.Skills,
            endpoint = endpoint,
            token = token,
        )
    }

    public suspend fun deleteSkill(id: String, endpoint: Endpoint, token: String) {
        performOp(
            request = ClientMessage.SkillDelete(id),
            kind = SyncKind.Skills,
            endpoint = endpoint,
            token = token,
        )
    }

    public suspend fun upsertMCPServer(server: MCPServer, endpoint: Endpoint, token: String) {
        performOp(
            request = ClientMessage.MCPUpsert(server),
            kind = SyncKind.MCP,
            endpoint = endpoint,
            token = token,
        )
    }

    public suspend fun deleteMCPServer(id: String, endpoint: Endpoint, token: String) {
        performOp(
            request = ClientMessage.MCPDelete(id),
            kind = SyncKind.MCP,
            endpoint = endpoint,
            token = token,
        )
    }

    /** Refresh skills + MCP one after the other. Errors are surfaced
     *  via [lastSyncError] instead of thrown so the caller can show a
     *  non-blocking error banner. */
    public suspend fun refreshAll(endpoint: Endpoint, token: String) {
        _lastSyncError.tryEmit(null)
        val skillsErr = runCatching { requestSkillsSync(endpoint, token) }
            .exceptionOrNull()
        if (skillsErr != null) {
            _lastSyncError.tryEmit(skillsErr.toUserMessage())
        }
        val mcpErr = runCatching { requestMCPSync(endpoint, token) }
            .exceptionOrNull()
        if (mcpErr != null) {
            val msg = mcpErr.toUserMessage()
            // Preserve the first error if no skills error was raised.
            _lastSyncError.tryEmit(if (skillsErr == null) msg else null.also {
                _lastSyncError.tryEmit(msg)
            })
        }
    }

    /** Run a single op, return only after the desktop's acknowledging
     *  sync (or [SkillsMCPError.Timeout] if it doesn't show up in
     *  time). Throws if the server reports an explicit error. */
    private suspend fun performOp(
        request: ClientMessage,
        kind: SyncKind,
        endpoint: Endpoint,
        token: String,
        timeoutSeconds: Long = 15,
    ) {
        val session = serverClient.connect(endpoint = endpoint, token = token)
        try {
            session.send(request)
            val deadline = System.currentTimeMillis() + timeoutSeconds * 1000
            while (true) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) throw SkillsMCPError.Timeout
                val next = withTimeoutOrNull(remaining) {
                    session.incoming.first()
                } ?: throw SkillsMCPError.Timeout
                when (next) {
                    is ServerMessage.SkillsSync -> {
                        if (kind == SyncKind.Skills) return
                    }
                    is ServerMessage.MCPSync -> {
                        if (kind == SyncKind.MCP) return
                    }
                    is ServerMessage.Error -> {
                        val msg = next.message
                        throw SkillsMCPError.ServerError(msg)
                    }
                    else -> continue
                }
            }
        } catch (e: SkillsMCPError) {
            throw e
        } catch (e: TimeoutCancellationException) {
            throw SkillsMCPError.Timeout
        } catch (e: Exception) {
            throw SkillsMCPError.ServerError(e.message ?: e.javaClass.simpleName)
        } finally {
            runCatching { session.close() }
        }
    }

    private enum class SyncKind { Skills, MCP }

    private fun Throwable.toUserMessage(): String = when (this) {
        is SkillsMCPError -> message ?: "Sync failed."
        else -> localizedMessage ?: message ?: javaClass.simpleName
    }
}
