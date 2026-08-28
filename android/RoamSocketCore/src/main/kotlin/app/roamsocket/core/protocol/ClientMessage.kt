/*
 * App → server WebSocket frames. kotlinx.serialization's sealed-class
 * discrimination (via @JsonClassDiscriminator) produces the same JSON the
 * TypeScript server validates with Zod: { "type": "...", ... }.
 */
package app.roamsocket.core.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonClassDiscriminator

@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
@JsonClassDiscriminator("type")
@Serializable
public sealed class ClientMessage {

    @Serializable
    @SerialName("create_session")
    public data class CreateSession(
        val sessionId: String? = null,
        val repo: RepoRef,
        val environment: EnvironmentConfig? = null,
        val model: ModelSelection,
        val permissionMode: PermissionMode = PermissionMode.ACCEPT_EDITS,
        val skills: List<String> = emptyList(),
        val mcpServers: List<MCPServer> = emptyList(),
    ) : ClientMessage()

    @Serializable
    @SerialName("user_message")
    public data class UserMessage(
        val sessionId: String,
        val text: String,
        /** Optional mid-session model switch. */
        val model: ModelSelection? = null,
    ) : ClientMessage()

    @Serializable
    @SerialName("permission_response")
    public data class PermissionResponse(
        val sessionId: String,
        val requestId: String,
        val decision: PermissionDecision,
    ) : ClientMessage()

    @Serializable
    @SerialName("interrupt")
    public data class Interrupt(val sessionId: String) : ClientMessage()

    @Serializable
    @SerialName("create_pr")
    public data class CreatePr(
        val sessionId: String,
        val title: String,
        val body: String = "",
    ) : ClientMessage()

    @Serializable
    @SerialName("git_publish")
    public data class GitPublish(
        val sessionId: String,
        val message: String = "",
        val commit: Boolean = false,
        val push: Boolean = false,
        val openPr: Boolean = false,
    ) : ClientMessage()

    @Serializable
    @SerialName("skills_sync_request")
    public data object SkillsSyncRequest : ClientMessage()

    @Serializable
    @SerialName("mcp_sync_request")
    public data object MCPSyncRequest : ClientMessage()

    @Serializable
    @SerialName("skill_upsert")
    public data class SkillUpsert(val skill: Skill) : ClientMessage()

    @Serializable
    @SerialName("skill_delete")
    public data class SkillDelete(val id: String) : ClientMessage()

    @Serializable
    @SerialName("mcp_upsert")
    public data class MCPUpsert(val server: MCPServer) : ClientMessage()

    @Serializable
    @SerialName("mcp_delete")
    public data class MCPDelete(val id: String) : ClientMessage()

    @Serializable
    @SerialName("memory_sync_request")
    public data object MemorySyncRequest : ClientMessage()

    @Serializable
    @SerialName("memory_upsert")
    public data class MemoryUpsert(val entry: MemoryEntryPayload) : ClientMessage()

    @Serializable
    @SerialName("memory_delete")
    public data class MemoryDelete(val id: String) : ClientMessage()

    @Serializable
    @SerialName("connector_list_request")
    public data object ConnectorListRequest : ClientMessage()

    @Serializable
    @SerialName("connector_set_token")
    public data class ConnectorSetToken(val id: String, val token: String) : ClientMessage()

    @Serializable
    @SerialName("connector_set_oauth_app")
    public data class ConnectorSetOAuthApp(
        val id: String,
        val clientId: String,
        val clientSecret: String? = null,
    ) : ClientMessage()

    @Serializable
    @SerialName("connector_oauth_start")
    public data class ConnectorOAuthStart(val id: String) : ClientMessage()

    @Serializable
    @SerialName("connector_disconnect")
    public data class ConnectorDisconnect(val id: String) : ClientMessage()

    @Serializable
    @SerialName("terminal_open")
    public data class TerminalOpen(
        val terminalId: String? = null,
        val sessionId: String,
        val cols: Int = 80,
        val rows: Int = 24,
    ) : ClientMessage()

    @Serializable
    @SerialName("terminal_input")
    public data class TerminalInput(val terminalId: String, val data: String) : ClientMessage()

    @Serializable
    @SerialName("terminal_resize")
    public data class TerminalResize(
        val terminalId: String,
        val cols: Int,
        val rows: Int,
    ) : ClientMessage()

    @Serializable
    @SerialName("terminal_kill")
    public data class TerminalKill(val terminalId: String) : ClientMessage()

    @Serializable
    @SerialName("file_list")
    public data class FileList(val sessionId: String, val path: String = "") : ClientMessage()

    @Serializable
    @SerialName("file_read")
    public data class FileRead(val sessionId: String, val path: String) : ClientMessage()

    @Serializable
    @SerialName("file_write")
    public data class FileWrite(
        val sessionId: String,
        val path: String,
        val content: String,
    ) : ClientMessage()

    @Serializable
    @SerialName("port_list")
    public data class PortList(val sessionId: String) : ClientMessage()

    @Serializable
    @SerialName("tunnel_start")
    public data class TunnelStart(
        val sessionId: String,
        val port: Int,
        val provider: TunnelProvider = TunnelProvider.AUTO,
    ) : ClientMessage()

    @Serializable
    @SerialName("tunnel_stop")
    public data class TunnelStop(val sessionId: String, val tunnelId: String) : ClientMessage()

    @Serializable
    @SerialName("tunnel_list")
    public data class TunnelList(val sessionId: String) : ClientMessage()

    @Serializable
    @SerialName("remote_endpoint_request")
    public data class RemoteEndpointRequest(val force: Boolean = false) : ClientMessage()

    // MARK: - E2B sandbox runs (E2B.dev)

    @Serializable
    @SerialName("e2b_start")
    public data class E2bStart(
        val sessionId: String,
        val command: String? = null,
        /** Per-connection user override. Server still uses the admin env key when null. */
        val apiKey: String? = null,
    ) : ClientMessage()

    @Serializable
    @SerialName("e2b_abort")
    public data class E2bAbort(val runId: String) : ClientMessage()

    @Serializable
    @SerialName("e2b_list")
    public data class E2bList(
        val sessionId: String? = null,
        val limit: Int = 50,
    ) : ClientMessage()

    @Serializable
    @SerialName("e2b_set_key")
    public data class E2bSetKey(val apiKey: String) : ClientMessage()
}

@Serializable
public enum class PermissionDecision {
    @SerialName("allow") ALLOW,
    @SerialName("deny") DENY,
}

@Serializable
public enum class TunnelProvider {
    @SerialName("auto") AUTO,
    @SerialName("ngrok") NGROK,
    @SerialName("cloudflare") CLOUDFLARE,
    @SerialName("localtunnel") LOCALTUNNEL,
    @SerialName("bore") BORE,
}

@Serializable
public data class RepoRef(
    val fullName: String,
    val baseBranch: String? = null,
    val workBranch: String,
    val githubToken: String? = null,
)
