/*
 * Server → app WebSocket frames. Same JSON shape the desktop encodes with
 * Zod (`desktop-server/src/protocol.ts`) and the iOS app decodes with
 * `Codable` (`ios/AnyProvCore/.../Protocol.swift`).
 */
package app.roamsocket.core.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonClassDiscriminator

@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
@JsonClassDiscriminator("type")
@Serializable
public sealed class ServerMessage {

    @Serializable
    @SerialName("session_created")
    public data class SessionCreated(
        val sessionId: String,
        val workdir: String,
        val baseBranch: String,
        val workBranch: String,
    ) : ServerMessage()

    @Serializable
    @SerialName("assistant_delta")
    public data class AssistantDelta(val sessionId: String, val text: String) : ServerMessage()

    @Serializable
    @SerialName("tool_call")
    public data class ToolCall(
        val sessionId: String,
        val callId: String,
        val tool: String,
        val summary: String,
        val input: Map<String, kotlinx.serialization.json.JsonElement> = emptyMap(),
    ) : ServerMessage()

    @Serializable
    @SerialName("tool_result")
    public data class ToolResult(
        val sessionId: String,
        val callId: String,
        val ok: Boolean,
        val output: String,
    ) : ServerMessage()

    @Serializable
    @SerialName("diff")
    public data class Diff(
        val sessionId: String,
        val path: String,
        val patch: String,
        val added: Int,
        val removed: Int,
    ) : ServerMessage()

    @Serializable
    @SerialName("permission_request")
    public data class PermissionRequest(
        val sessionId: String,
        val requestId: String,
        val tool: String,
        val summary: String,
    ) : ServerMessage()

    @Serializable
    @SerialName("session_done")
    public data class SessionDone(
        val sessionId: String,
        val stopReason: String? = null,
    ) : ServerMessage()

    @Serializable
    @SerialName("pr_created")
    public data class PrCreated(val sessionId: String, val url: String) : ServerMessage()

    @Serializable
    @SerialName("git_result")
    public data class GitResult(
        val sessionId: String,
        val action: String,
        val ok: Boolean,
        val detail: String,
        val url: String? = null,
    ) : ServerMessage()

    @Serializable
    @SerialName("error")
    public data class Error(
        val sessionId: String? = null,
        val message: String,
    ) : ServerMessage()

    @Serializable
    @SerialName("skills_sync")
    public data class SkillsSync(val skills: List<Skill>) : ServerMessage()

    @Serializable
    @SerialName("mcp_sync")
    public data class MCPSync(val servers: List<MCPServer>) : ServerMessage()

    @Serializable
    @SerialName("memory_sync")
    public data class MemorySync(val entries: List<MemoryEntryPayload>) : ServerMessage()

    @Serializable
    @SerialName("connector_status")
    public data class ConnectorStatusMsg(val connectors: List<ConnectorStatus>) : ServerMessage()

    @Serializable
    @SerialName("terminal_data")
    public data class TerminalData(
        val terminalId: String,
        val stream: TerminalStream,
        val data: String,
    ) : ServerMessage()

    @Serializable
    @SerialName("terminal_control")
    public data class TerminalControl(
        val terminalId: String,
        val event: TerminalEvent,
        val code: Int,
    ) : ServerMessage()

    @Serializable
    @SerialName("file_list_result")
    public data class FileListResult(
        val sessionId: String,
        val path: String,
        val entries: List<FileEntry>,
        val diff: String? = null,
        val changes: List<FileChange>? = null,
    ) : ServerMessage()

    @Serializable
    @SerialName("file_read_result")
    public data class FileReadResult(
        val sessionId: String,
        val path: String,
        val content: String,
        val truncated: Boolean,
        val diff: String? = null,
    ) : ServerMessage()

    @Serializable
    @SerialName("file_write_result")
    public data class FileWriteResult(
        val sessionId: String,
        val path: String,
        val ok: Boolean,
        val message: String? = null,
    ) : ServerMessage()

    @Serializable
    @SerialName("port_list_result")
    public data class PortListResult(
        val sessionId: String,
        val ports: List<ListeningPort>,
    ) : ServerMessage()

    @Serializable
    @SerialName("tunnel_status")
    public data class TunnelStatus(
        val sessionId: String,
        val tunnels: List<TunnelInfo>,
        val availableProviders: List<String> = emptyList(),
    ) : ServerMessage()

    @Serializable
    @SerialName("remote_endpoint")
    public data class RemoteEndpoint(
        val status: RemoteEndpointStatus,
        val url: String? = null,
        val provider: String? = null,
        val error: String? = null,
    ) : ServerMessage()

    @Serializable
    @SerialName("task_list")
    public data class TaskList(val sessionId: String, val tasks: List<AgentTaskItem>) : ServerMessage()

    @Serializable
    @SerialName("goal_status")
    public data class GoalStatus(
        val sessionId: String,
        val status: GoalState,
        val condition: String? = null,
        val reason: String? = null,
        val turnsEvaluated: Int? = null,
        val startedAt: Long? = null,
        val elapsedMs: Long? = null,
        val message: String,
    ) : ServerMessage()

    @Serializable
    @SerialName("model_status")
    public data class ModelStatus(
        val sessionId: String,
        val status: ModelState,
        val hubId: String? = null,
        val message: String? = null,
    ) : ServerMessage()

    @Serializable
    @SerialName("transcript_replay")
    public data class TranscriptReplay(
        val sessionId: String,
        val events: List<TranscriptEvent>,
        val truncated: Boolean = false,
        val isLive: Boolean = false,
    ) : ServerMessage()

    // MARK: - E2B sandbox runs (E2B.dev)

    @Serializable
    @SerialName("e2b_started")
    public data class E2bStarted(
        val sessionId: String,
        val run: E2bRun,
    ) : ServerMessage()

    @Serializable
    @SerialName("e2b_log")
    public data class E2bLog(
        val runId: String,
        val sessionId: String,
        val stream: TerminalStream,
        val line: String,
        val ts: Long,
    ) : ServerMessage()

    @Serializable
    @SerialName("e2b_status")
    public data class E2bStatus(
        val sessionId: String,
        val run: E2bRun,
    ) : ServerMessage()

    @Serializable
    @SerialName("e2b_list")
    public data class E2bList(
        val sessionId: String? = null,
        val runs: List<E2bRun> = emptyList(),
    ) : ServerMessage()

    @Serializable
    @SerialName("e2b_key_ack")
    public data class E2bKeyAck(val overrideActive: Boolean) : ServerMessage()
}

/**
 * One event in a [ServerMessage.TranscriptReplay] payload. Mirrors the TS
 * `TranscriptEvent` discriminated union so the server can replay the same
 * shape on reattach that it would have streamed live.
 */
@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
@JsonClassDiscriminator("type")
@Serializable
public sealed class TranscriptEvent {
    @Serializable
    @SerialName("user")
    public data class User(val ts: Long, val text: String) : TranscriptEvent()

    @Serializable
    @SerialName("assistant_delta")
    public data class AssistantDelta(val sessionId: String, val text: String) : TranscriptEvent()

    @Serializable
    @SerialName("tool_call")
    public data class ToolCall(
        val sessionId: String,
        val callId: String,
        val tool: String,
        val summary: String,
    ) : TranscriptEvent()

    @Serializable
    @SerialName("tool_result")
    public data class ToolResult(
        val sessionId: String,
        val callId: String,
        val ok: Boolean,
        val output: String,
    ) : TranscriptEvent()

    @Serializable
    @SerialName("diff")
    public data class Diff(
        val sessionId: String,
        val path: String,
        val patch: String,
        val added: Int,
        val removed: Int,
    ) : TranscriptEvent()
}

@Serializable
public data class FileEntry(
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    val size: Long,
    val modifiedAt: String,
    /** Git short status when dirty: M, A, D, ?, … */
    val changeStatus: String? = null,
)

@Serializable
public data class FileChange(val path: String, val status: String)

@Serializable
public data class ListeningPort(val port: Int, val pid: Int, val command: String)

@Serializable
public data class TunnelInfo(
    val id: String,
    val port: Int,
    val provider: String,
    val status: TunnelStatusState,
    val url: String? = null,
    val error: String? = null,
)

@Serializable
public data class AgentTaskItem(
    val id: String,
    val content: String,
    val status: AgentTaskStatus,
)

@Serializable
public data class ConnectorStatus(
    val id: String,
    val name: String,
    val authType: ConnectorAuthType,
    val connected: Boolean,
    val helpText: String,
    val error: String? = null,
)

@Serializable
public enum class ConnectorAuthType {
    @SerialName("token") TOKEN,
    @SerialName("oauth2") OAUTH2,
    @SerialName("unsupported") UNSUPPORTED,
}

@Serializable
public enum class TerminalStream {
    @SerialName("out") OUT,
    @SerialName("err") ERR,
}

@Serializable
public enum class TerminalEvent {
    @SerialName("ready") READY,
    @SerialName("exit") EXIT,
}

@Serializable
public enum class TunnelStatusState {
    @SerialName("starting") STARTING,
    @SerialName("up") UP,
    @SerialName("error") ERROR,
    @SerialName("stopped") STOPPED,
}

@Serializable
public enum class RemoteEndpointStatus {
    @SerialName("starting") STARTING,
    @SerialName("up") UP,
    @SerialName("error") ERROR,
}

@Serializable
public enum class AgentTaskStatus {
    @SerialName("pending") PENDING,
    @SerialName("in_progress") IN_PROGRESS,
    @SerialName("completed") COMPLETED,
    @SerialName("cancelled") CANCELLED,
}

@Serializable
public enum class GoalState {
    @SerialName("active") ACTIVE,
    @SerialName("achieved") ACHIEVED,
    @SerialName("cleared") CLEARED,
    @SerialName("none") NONE,
}

@Serializable
public enum class ModelState {
    @SerialName("loading") LOADING,
    @SerialName("generating") GENERATING,
    @SerialName("done") DONE,
}

@Serializable
public enum class E2bRunState {
    @SerialName("queued") QUEUED,
    @SerialName("running") RUNNING,
    @SerialName("completed") COMPLETED,
    @SerialName("failed") FAILED,
    @SerialName("killed") KILLED,
}

@Serializable
public data class E2bRun(
    val id: String,
    val sessionId: String,
    val repoFullName: String,
    val branch: String,
    val command: String = "",
    val status: E2bRunState,
    val exitCode: Int? = null,
    val sandboxId: String? = null,
    val sandboxUrl: String? = null,
    val startedAt: Long? = null,
    val finishedAt: Long? = null,
    val outputTail: List<String> = emptyList(),
    val error: String? = null,
)
