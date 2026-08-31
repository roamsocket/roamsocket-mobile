package app.roamsocket.core.protocol

import app.roamsocket.core.providers.AIModel
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * Cross-platform parity runner (Android side).
 *
 * Loads shared JSON fixtures from `docs/parity/` at the repo root and
 * asserts RoamSocketCore produces the exact expected results. The iOS
 * runner (`ios/AnyProvCore/Tests/.../ParityTests.swift`) loads the same
 * files, so a behavior change on one platform that diverges from the
 * other fails here or there.
 *
 * See `docs/parity/README.md` for the fixture format.
 */
class ParityTest {

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
        classDiscriminator = "type"
    }

    // MARK: - Fixture loading

    /** Repo root relative to the module dir: RoamSocketCore is at `<root>/android/RoamSocketCore`. */
    private fun parityDir(): File {
        var dir = File(System.getProperty("user.dir"))
        // Gradle test working dir is the module dir; walk up to the repo root.
        while (dir != null && !File(dir, "docs/parity").isDirectory) {
            dir = dir.parentFile
        }
        requireNotNull(dir) { "could not locate docs/parity above ${System.getProperty("user.dir")}" }
        return File(dir, "docs/parity")
    }

    private fun fixture(name: String): JsonObject =
        json.parseToJsonElement(File(parityDir(), name).readText()).jsonObject

    private fun cases(fixture: JsonObject): List<JsonObject> =
        fixture["cases"]!!.jsonArray.map { it.jsonObject }

    private fun caseName(case: JsonObject): String =
        case["name"]?.jsonPrimitive?.content ?: "?"

    // MARK: - Normalized comparison

    /** Compare two JsonElements with key-order-insensitive object comparison. */
    private fun assertNormalized(expected: JsonElement, actual: JsonElement, op: String, name: String) {
        if (normalized(expected) != normalized(actual)) {
            fail(
                "[$op] case $name mismatch\n expected: $expected\n   actual: $actual",
            )
        }
    }

    /** Sort object keys recursively so comparison is order-insensitive. */
    private fun normalized(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(
            element.entries.associate { (k, v) -> k to normalized(v) }.toSortedMap(),
        )
        is JsonArray -> JsonArray(element.map { normalized(it) })
        else -> element
    }

    private fun <K : Comparable<K>> Map<K, JsonElement>.toSortedMap(): Map<K, JsonElement> =
        entries.sortedBy { it.key }.associate { it.key to it.value }

    // MARK: - decode_server_message

    @Test
    fun `decode server message parity`() {
        val fixture = fixture("protocol-cases.json")
        val op = fixture["op"]!!.jsonPrimitive.content
        for (case in cases(fixture)) {
            val name = caseName(case)
            val input = case["input"]!!.jsonPrimitive.content
            val expected = case["expected"]!!.jsonObject

            val actual: JsonElement = try {
                normalize(json.decodeFromString(ServerMessage.serializer(), input))
            } catch (e: Exception) {
                // Unknown discriminator and malformed payloads must fail decode
                // on every platform; expectation is `kind == "error"`.
                JsonObject(mapOf("kind" to JsonPrimitive("error")))
            }
            assertNormalized(expected, actual, op, name)
        }
    }

    /** Map a decoded ServerMessage into the normalized JSON form shared by both runners. */
    private fun normalize(msg: ServerMessage): JsonElement = when (msg) {
        is ServerMessage.SessionCreated -> obj(
            "kind" to "session_created",
            "sessionId" to msg.sessionId, "workdir" to msg.workdir,
            "baseBranch" to msg.baseBranch, "workBranch" to msg.workBranch,
        )
        is ServerMessage.AssistantDelta -> obj(
            "kind" to "assistant_delta",
            "sessionId" to msg.sessionId, "text" to msg.text,
        )
        is ServerMessage.ToolCall -> obj(
            "kind" to "tool_call",
            "sessionId" to msg.sessionId, "callId" to msg.callId,
            "tool" to msg.tool, "summary" to msg.summary,
        )
        is ServerMessage.ToolResult -> obj(
            "kind" to "tool_result",
            "sessionId" to msg.sessionId, "callId" to msg.callId,
            "ok" to msg.ok, "output" to msg.output,
        )
        is ServerMessage.Diff -> obj(
            "kind" to "diff",
            "sessionId" to msg.sessionId, "path" to msg.path, "patch" to msg.patch,
            "added" to msg.added, "removed" to msg.removed,
        )
        is ServerMessage.PermissionRequest -> obj(
            "kind" to "permission_request",
            "sessionId" to msg.sessionId, "requestId" to msg.requestId,
            "tool" to msg.tool, "summary" to msg.summary,
        )
        is ServerMessage.SessionDone -> obj(
            "kind" to "session_done",
            "sessionId" to msg.sessionId, "stopReason" to (msg.stopReason ?: JsonNull),
        )
        is ServerMessage.PrCreated -> obj(
            "kind" to "pr_created", "sessionId" to msg.sessionId, "url" to msg.url,
        )
        is ServerMessage.GitResult -> obj(
            "kind" to "git_result",
            "sessionId" to msg.sessionId, "action" to msg.action, "ok" to msg.ok,
            "detail" to msg.detail, "url" to (msg.url ?: JsonNull),
        )
        is ServerMessage.Error -> obj(
            "kind" to "error",
            "sessionId" to (msg.sessionId ?: JsonNull), "message" to msg.message,
        )
        is ServerMessage.FileWriteResult -> obj(
            "kind" to "file_write_result",
            "sessionId" to msg.sessionId, "path" to msg.path, "ok" to msg.ok,
            "message" to (msg.message ?: JsonNull),
        )
        is ServerMessage.FileListResult -> obj(
            "kind" to "file_list_result",
            "sessionId" to msg.sessionId, "path" to msg.path,
            "entries" to JsonArray(msg.entries.map { e ->
                obj(
                    "name" to e.name, "path" to e.path, "isDirectory" to e.isDirectory,
                    "size" to e.size, "modifiedAt" to e.modifiedAt,
                    "changeStatus" to (e.changeStatus ?: JsonNull),
                )
            }),
            "diff" to (msg.diff ?: JsonNull),
            "changes" to JsonArray((msg.changes ?: emptyList()).map { c ->
                obj("path" to c.path, "status" to c.status)
            }),
        )
        is ServerMessage.PortListResult -> obj(
            "kind" to "port_list_result",
            "sessionId" to msg.sessionId,
            "ports" to JsonArray(msg.ports.map { p ->
                obj("port" to p.port, "pid" to p.pid, "command" to p.command)
            }),
        )
        is ServerMessage.TunnelStatus -> obj(
            "kind" to "tunnel_status",
            "sessionId" to msg.sessionId,
            "tunnels" to JsonArray(msg.tunnels.map { t ->
                obj(
                    "id" to t.id, "port" to t.port, "provider" to t.provider,
                    "status" to t.status.name.lowercase(), "url" to (t.url ?: JsonNull),
                )
            }),
            "availableProviders" to JsonArray(msg.availableProviders.map { JsonPrimitive(it) }),
        )
        is ServerMessage.RemoteEndpoint -> obj(
            "kind" to "remote_endpoint",
            "status" to msg.status.name.lowercase(), "url" to (msg.url ?: JsonNull),
            "provider" to (msg.provider ?: JsonNull), "error" to (msg.error ?: JsonNull),
        )
        is ServerMessage.TaskList -> obj(
            "kind" to "task_list",
            "sessionId" to msg.sessionId,
            "tasks" to JsonArray(msg.tasks.map { t ->
                obj("id" to t.id, "content" to t.content, "status" to t.status.name.lowercase())
            }),
        )
        is ServerMessage.GoalStatus -> obj(
            "kind" to "goal_status",
            "sessionId" to msg.sessionId, "status" to msg.status.name.lowercase(),
            "condition" to (msg.condition ?: JsonNull), "reason" to (msg.reason ?: JsonNull),
            "turnsEvaluated" to (msg.turnsEvaluated ?: JsonNull),
            "startedAt" to (msg.startedAt ?: JsonNull),
            "elapsedMs" to (msg.elapsedMs ?: JsonNull),
            "message" to msg.message,
        )
        is ServerMessage.ModelStatus -> obj(
            "kind" to "model_status",
            "sessionId" to msg.sessionId, "status" to msg.status.name.lowercase(),
            "hubID" to (msg.hubId ?: JsonNull), "message" to (msg.message ?: JsonNull),
        )
        is ServerMessage.TranscriptReplay -> obj(
            "kind" to "transcript_replay",
            "sessionId" to msg.sessionId,
            "truncated" to msg.truncated, "isLive" to msg.isLive,
            "events" to JsonArray(msg.events.map { e ->
                when (e) {
                    is TranscriptEvent.User -> obj(
                        "kind" to "user", "ts" to e.ts, "text" to e.text,
                    )
                    is TranscriptEvent.AssistantDelta -> obj(
                        "kind" to "assistant_delta", "sessionId" to e.sessionId, "text" to e.text,
                    )
                    is TranscriptEvent.ToolCall -> obj(
                        "kind" to "tool_call", "sessionId" to e.sessionId, "callId" to e.callId,
                        "tool" to e.tool, "summary" to e.summary,
                    )
                    is TranscriptEvent.ToolResult -> obj(
                        "kind" to "tool_result", "sessionId" to e.sessionId, "callId" to e.callId,
                        "ok" to e.ok, "output" to e.output,
                    )
                    is TranscriptEvent.Diff -> obj(
                        "kind" to "diff", "sessionId" to e.sessionId, "path" to e.path,
                        "patch" to e.patch, "added" to e.added, "removed" to e.removed,
                    )
                }
            }),
        )
        is ServerMessage.E2bList -> obj(
            "kind" to "e2b_list",
            "sessionId" to (msg.sessionId ?: JsonNull),
            "runs" to JsonArray(msg.runs.map { r ->
                obj(
                    "id" to r.id, "sessionId" to r.sessionId, "repoFullName" to r.repoFullName,
                    "branch" to r.branch, "command" to r.command, "status" to r.status.name.lowercase(),
                    "exitCode" to (r.exitCode ?: JsonNull),
                    "sandboxId" to (r.sandboxId ?: JsonNull),
                    "sandboxUrl" to (r.sandboxUrl ?: JsonNull),
                    "startedAt" to (r.startedAt ?: JsonNull),
                    "finishedAt" to (r.finishedAt ?: JsonNull),
                    "outputTail" to JsonArray(r.outputTail.map { JsonPrimitive(it) }),
                    "error" to (r.error ?: JsonNull),
                )
            }),
        )
        is ServerMessage.E2bKeyAck -> obj(
            "kind" to "e2b_key_ack", "overrideActive" to msg.overrideActive,
        )
        else -> obj("kind" to "unhandled_parity_case")
    }

    private fun obj(vararg pairs: Pair<String, Any?>): JsonObject = JsonObject(
        pairs.associate { (k, v) ->
            k to when (v) {
                null -> JsonNull
                is JsonElement -> v
                is String -> JsonPrimitive(v)
                is Boolean -> JsonPrimitive(v)
                is Int -> JsonPrimitive(v)
                is Long -> JsonPrimitive(v)
                is List<*> -> JsonArray(v.map { anyToElement(it) })
                else -> JsonPrimitive(v.toString())
            }
        },
    )

    private fun anyToElement(v: Any?): JsonElement = when (v) {
        null -> JsonNull
        is JsonElement -> v
        is String -> JsonPrimitive(v)
        is Boolean -> JsonPrimitive(v)
        is Int -> JsonPrimitive(v)
        is Long -> JsonPrimitive(v)
        else -> JsonPrimitive(v.toString())
    }

    // MARK: - encode_client_message

    @Test
    fun `encode client message parity`() {
        val fixture = fixture("protocol-encode-cases.json")
        val op = fixture["op"]!!.jsonPrimitive.content
        for (case in cases(fixture)) {
            val name = caseName(case)
            val input = case["input"]!!.jsonObject
            val expected = case["expected"]!!.jsonObject

            val msg = clientMessage(input)
            val encoded = encodeJson.encodeToString(ClientMessage.serializer(), msg)
            val obj = json.parseToJsonElement(encoded).jsonObject

            // Subset compare: expected keys must be present with exact values;
            // extra keys the platform emits (e.g. default leakage) fail.
            for ((key, want) in expected) {
                val got: JsonElement = obj[key]
                    ?: return fail("[$op] case $name missing key $key (encoded: $encoded)")
                assertNormalized(want, got, op, name)
            }
        }
    }

    /** Mirrors ServerClient's wire encoder: defaults encoded, nulls dropped. */
    private val encodeJson = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
        classDiscriminator = "type"
    }

    private fun clientMessage(input: JsonObject): ClientMessage {
        val caseName = input["case"]!!.jsonPrimitive.content
        val str = { key: String -> input[key]?.jsonPrimitive?.content }
        val int = { key: String -> input[key]?.jsonPrimitive?.content?.toInt() }
        val bool = { key: String -> input[key]?.jsonPrimitive?.content?.toBooleanStrictOrNull() }

        fun modelSelection(dict: JsonObject?): ModelSelection? {
            if (dict == null) return null
            return ModelSelection(
                provider = dict["provider"]!!.jsonPrimitive.content,
                model = dict["model"]!!.jsonPrimitive.content,
                effort = Effort.valueOf(
                    (dict["effort"]?.jsonPrimitive?.content ?: "high").uppercase(),
                ),
                apiKey = dict["apiKey"]!!.jsonPrimitive.content,
            )
        }

        return when (caseName) {
            "user_message" -> ClientMessage.UserMessage(
                sessionId = str("sessionId")!!,
                text = str("text")!!,
                model = modelSelection(input["model"] as? JsonObject),
            )
            "interrupt" -> ClientMessage.Interrupt(sessionId = str("sessionId")!!)
            "skills_sync_request" -> ClientMessage.SkillsSyncRequest
            "git_publish" -> ClientMessage.GitPublish(
                sessionId = str("sessionId")!!,
                message = str("message") ?: "",
                commit = bool("commit") ?: false,
                push = bool("push") ?: false,
                openPr = bool("openPr") ?: false,
            )
            "file_write" -> ClientMessage.FileWrite(
                sessionId = str("sessionId")!!,
                path = str("path")!!,
                content = str("content")!!,
            )
            "tunnel_start" -> ClientMessage.TunnelStart(
                sessionId = str("sessionId")!!,
                port = int("port")!!,
                provider = TunnelProvider.valueOf(
                    (str("provider") ?: "auto").uppercase(),
                ),
            )
            "remote_endpoint_request" -> ClientMessage.RemoteEndpointRequest(
                force = bool("force") ?: false,
            )
            "create_session" -> ClientMessage.CreateSession(
                sessionId = str("sessionId"),
                repo = RepoRef(
                    fullName = (input["repo"] as JsonObject)["fullName"]!!.jsonPrimitive.content,
                    workBranch = (input["repo"] as JsonObject)["workBranch"]!!.jsonPrimitive.content,
                ),
                environment = (input["environment"] as? JsonObject)?.let { env ->
                    EnvironmentConfig(
                        name = env["name"]!!.jsonPrimitive.content,
                        variables = (env["variables"] as? JsonObject)?.entries?.associate {
                            it.key to it.value.jsonPrimitive.content
                        } ?: emptyMap(),
                    )
                },
                model = modelSelection(input["model"] as JsonObject)!!,
                permissionMode = when (str("permissionMode") ?: "acceptEdits") {
                    "acceptEdits" -> PermissionMode.ACCEPT_EDITS
                    "plan" -> PermissionMode.PLAN
                    else -> PermissionMode.ASK
                },
                skills = (input["skills"] as? JsonArray)?.map { it.jsonPrimitive.content } ?: emptyList(),
                mcpServers = (input["mcpServers"] as? JsonArray)?.map { s ->
                    val d = s.jsonObject
                    MCPServer(
                        id = d["id"]!!.jsonPrimitive.content,
                        name = d["name"]!!.jsonPrimitive.content,
                        description = d["description"]!!.jsonPrimitive.content,
                        command = d["command"]!!.jsonPrimitive.content,
                        args = (d["args"] as? JsonArray)?.map { it.jsonPrimitive.content } ?: emptyList(),
                        env = (d["env"] as? JsonObject)?.entries?.associate {
                            it.key to it.value.jsonPrimitive.content
                        } ?: emptyMap(),
                        isEnabled = d["isEnabled"]?.jsonPrimitive?.content?.toBooleanStrictOrNull() ?: true,
                    )
                } ?: emptyList(),
            )
            else -> error("runner does not implement encode case: $caseName")
        }
    }

    // MARK: - parse_env

    @Test
    fun `parse env parity`() {
        val fixture = fixture("env-cases.json")
        val op = fixture["op"]!!.jsonPrimitive.content
        for (case in cases(fixture)) {
            val name = caseName(case)
            val input = case["input"]!!.jsonPrimitive.content
            val expectedVars = (case["expected"]!!.jsonObject["vars"] as JsonObject)
                .entries.associate { it.key to it.value.jsonPrimitive.content }

            val parsed = EnvironmentConfig.parseEnv(input)
            assertEquals("[$op] case $name", expectedVars, parsed)
        }
    }

    // MARK: - prettify_display_name

    @Test
    fun `prettify display name parity`() {
        val fixture = fixture("model-cases.json")
        val op = fixture["op"]!!.jsonPrimitive.content
        for (case in cases(fixture)) {
            val name = caseName(case)
            val input = case["input"]!!.jsonPrimitive.content
            val want = case["expected"]!!.jsonObject["name"]!!.jsonPrimitive.content

            val got = AIModel.prettifiedDisplayName(input)
            assertEquals("[$op] case $name", want, got)
        }
    }
}
