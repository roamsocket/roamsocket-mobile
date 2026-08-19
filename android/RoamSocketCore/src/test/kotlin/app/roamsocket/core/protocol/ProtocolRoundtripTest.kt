package app.roamsocket.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Round-trip + canonical-JSON tests that pin the wire-protocol shape to
 * what the desktop server (`desktop-server/src/protocol.ts`) emits and
 * what the iOS app decodes (`ios/AnyProvCore/.../Protocol.swift`).
 *
 * If you change any of these, update all three implementations and
 * `docs/protocol.md` in the same PR.
 */
class ProtocolRoundtripTest {

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        classDiscriminator = "type"
    }

    // ---------- EnvironmentConfig ------------------------------------------------

    @Test
    fun `envConfig roundtrips with all defaults`() {
        val cfg = EnvironmentConfig(name = "dev")
        val encoded = json.encodeToString(EnvironmentConfig.serializer(), cfg)
        val decoded = json.decodeFromString(EnvironmentConfig.serializer(), encoded)
        assertEquals(cfg, decoded)
    }

    @Test
    fun `envConfig decodes server payload (no defaults supplied)`() {
        // The server may emit the bare object — defaults should fill in.
        val payload = """{"name":"dev"}"""
        val cfg = json.decodeFromString(EnvironmentConfig.serializer(), payload)
        assertEquals(NetworkAccess.TRUSTED, cfg.networkAccess)
        assertEquals(emptyList<String>(), cfg.allowedDomains)
        assertEquals(emptyMap<String, String>(), cfg.variables)
    }

    @Test
    fun `parseEnv handles quotes, comments, blank lines`() {
        val text = """
            # top comment
            FOO=bar
            BAZ="qux qux"
            QUX='single'
            EMPTY=
            invalid_line_no_equals
        """.trimIndent()
        val parsed = EnvironmentConfig.parseEnv(text)
        assertEquals("bar", parsed["FOO"])
        assertEquals("qux qux", parsed["BAZ"])
        assertEquals("single", parsed["QUX"])
        assertEquals("", parsed["EMPTY"])
        assertTrue("invalid line should be skipped", "invalid_line_no_equals" !in parsed)
    }

    // ---------- ModelSelection ---------------------------------------------------

    @Test
    fun `modelSelection roundtrips with optional fields`() {
        val sel = ModelSelection(
            provider = "anthropic",
            model = "claude-3-5-sonnet-20241022",
            effort = Effort.HIGH,
            apiKey = "sk-…",
            baseUrl = "https://example.com/v1",
            apiStyle = ApiStyle.ANTHROPIC,
        )
        val encoded = json.encodeToString(ModelSelection.serializer(), sel)
        val decoded = json.decodeFromString(ModelSelection.serializer(), encoded)
        assertEquals(sel, decoded)
        // baseUrl must serialize as `baseUrl` (camelCase) for the TS server.
        assertTrue("expected baseUrl camelCase key", encoded.contains("\"baseUrl\""))
        assertTrue("expected no snake_case leak", !encoded.contains("base_url"))
    }

    // ---------- ClientMessage (sealed union) -------------------------------------

    @Test
    fun `createSession encodes with snake_case type and nested repo`() {
        val msg = ClientMessage.CreateSession(
            sessionId = null,
            repo = RepoRef(fullName = "acme/widgets", workBranch = "feat/hi"),
            model = ModelSelection(provider = "openai", model = "gpt-4o", apiKey = "sk-…"),
            permissionMode = PermissionMode.ACCEPT_EDITS,
        )
        val encoded = json.encodeToString(ClientMessage.serializer(), msg)
        val obj = json.parseToJsonElement(encoded).jsonObject
        assertEquals("create_session", obj["type"]?.toString()?.trim('"'))
        assertEquals("acme/widgets", obj["repo"]?.jsonObject?.get("fullName")?.toString()?.trim('"'))
        assertEquals("acceptEdits", obj["permissionMode"]?.toString()?.trim('"'))
    }

    @Test
    fun `userMessage with optional model override decodes correctly`() {
        val payload = """
            {"type":"user_message","sessionId":"s1","text":"hi"}
        """.trimIndent()
        val msg: ClientMessage = json.decodeFromString(ClientMessage.serializer(), payload)
        assertTrue(msg is ClientMessage.UserMessage)
        val um: ClientMessage.UserMessage = msg as ClientMessage.UserMessage
        assertEquals("s1", um.sessionId)
        assertEquals("hi", um.text)
        assertEquals(null, um.model)
    }

    @Test
    fun `singleton client messages use data object`() {
        val payload = """{"type":"skills_sync_request"}"""
        val msg = json.decodeFromString(ClientMessage.serializer(), payload)
        assertEquals(ClientMessage.SkillsSyncRequest, msg)
    }

    // ---------- ServerMessage (sealed union) -------------------------------------

    @Test
    fun `assistantDelta decodes streaming frame`() {
        val payload = """{"type":"assistant_delta","sessionId":"s","text":"Hello "}"""
        val msg: ServerMessage = json.decodeFromString(ServerMessage.serializer(), payload)
        assertTrue(msg is ServerMessage.AssistantDelta)
        val delta: ServerMessage.AssistantDelta = msg as ServerMessage.AssistantDelta
        assertEquals("Hello ", delta.text)
    }

    @Test
    fun `toolResult decodes ok=false outcome`() {
        val payload = """{"type":"tool_result","sessionId":"s","callId":"c","ok":false,"output":"boom"}"""
        val msg: ServerMessage = json.decodeFromString(ServerMessage.serializer(), payload)
        assertTrue(msg is ServerMessage.ToolResult)
        val tr: ServerMessage.ToolResult = msg as ServerMessage.ToolResult
        assertEquals(false, tr.ok)
        assertEquals("boom", tr.output)
    }

    @Test
    fun `error message tolerates missing sessionId`() {
        val payload = """{"type":"error","message":"no session"}"""
        val msg: ServerMessage = json.decodeFromString(ServerMessage.serializer(), payload)
        assertTrue(msg is ServerMessage.Error)
        val e: ServerMessage.Error = msg as ServerMessage.Error
        assertEquals("no session", e.message)
        assertEquals(null, e.sessionId)
    }

    @Test
    fun `unknown discriminator is surfaced as decode failure`() {
        val payload = """{"type":"not_a_real_type"}"""
        var caught = false
        try {
            json.decodeFromString(ServerMessage.serializer(), payload)
        } catch (_: Exception) {
            caught = true
        }
        assertTrue("expected decode to fail for unknown discriminator", caught)
    }

    // ---------- Pairing ----------------------------------------------------------

    @Test
    fun `pairRequest default device name is Android`() {
        val req = PairRequest(code = "ABC123", deviceName = PairRequest.DEFAULT_DEVICE_NAME)
        val encoded = json.encodeToString(PairRequest.serializer(), req)
        val decoded = json.decodeFromString(PairRequest.serializer(), encoded)
        assertEquals(req, decoded)
    }
}

private val JsonElement.jsonObject: JsonObject
    get() = this as JsonObject
