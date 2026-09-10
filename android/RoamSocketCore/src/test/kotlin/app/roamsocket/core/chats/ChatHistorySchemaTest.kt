package app.roamsocket.core.chats

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lock the on-disk shape of [ChatHistoryItem] / [PersistedChatMessage].
 *
 * Adding a new field is fine; renaming or retyping an existing one
 * requires a migration in `ChatHistoryRepository`. This test catches
 * accidental renames before they ship.
 */
class ChatHistorySchemaTest {

    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint = false
    }

    @Test
    fun roundtripsACompleteChat() {
        val original = ChatHistoryItem(
            id = "11111111-1111-1111-1111-111111111111",
            title = "Designing the wire protocol",
            lastMessageAtMillis = 1_700_000_000_000,
            messages = listOf(
                PersistedChatMessage(
                    id = "m-1",
                    role = PersistedChatMessage.Role.USER,
                    content = "Sketch the message envelope.",
                    timestampMillis = 1_699_999_900_000,
                ),
                PersistedChatMessage(
                    id = "m-2",
                    role = PersistedChatMessage.Role.ASSISTANT,
                    content = "Sure — `{type, id, payload}` with a `type` discriminator.",
                    timestampMillis = 1_700_000_000_000,
                ),
            ),
            isArchived = false,
        )
        val encoded = json.encodeToString(ChatHistoryItem.serializer(), original)
        val decoded = json.decodeFromString(ChatHistoryItem.serializer(), encoded)
        assertEquals(original, decoded)
    }

    @Test
    fun blankDraftStaysBlank() {
        val item = ChatHistoryItem(
            id = "blank",
            title = ChatHistoryItem.DEFAULT_TITLE,
            lastMessageAtMillis = 0L,
        )
        assertTrue(item.isBlankDraft)
        val encoded = json.encodeToString(ChatHistoryItem.serializer(), item)
        val decoded = json.decodeFromString(ChatHistoryItem.serializer(), encoded)
        assertEquals(item, decoded)
        assertTrue(decoded.isBlankDraft)
    }

    @Test
    fun systemRoleRoundtrips() {
        val msg = PersistedChatMessage(
            id = "m-sys",
            role = PersistedChatMessage.Role.SYSTEM,
            content = "You are a careful assistant.",
            timestampMillis = 42L,
        )
        val encoded = json.encodeToString(PersistedChatMessage.serializer(), msg)
        assertTrue("expected system role to serialize as 'system', got: $encoded", encoded.contains("\"role\":\"system\""))
        val decoded = json.decodeFromString(PersistedChatMessage.serializer(), encoded)
        assertEquals(msg, decoded)
    }

    @Test
    fun failedDeliveryRoundtrips() {
        val msg = PersistedChatMessage(
            id = "m-fail",
            role = PersistedChatMessage.Role.USER,
            content = "Why?",
            timestampMillis = 7L,
            delivery = PersistedChatMessage.Delivery.FAILED,
        )
        val encoded = json.encodeToString(PersistedChatMessage.serializer(), msg)
        assertTrue(
            "expected failed delivery to serialize as 'failed', got: $encoded",
            encoded.contains("\"delivery\":\"failed\""),
        )
        val decoded = json.decodeFromString(PersistedChatMessage.serializer(), encoded)
        assertEquals(msg, decoded)
    }

    @Test
    fun legacyRowsWithoutDeliveryDefaultToSent() {
        // Hand-written legacy JSON (no `delivery` key) must deserialize.
        val legacy = """{"id":"x","role":"user","content":"hi","timestampMillis":1}"""
        val decoded = json.decodeFromString(PersistedChatMessage.serializer(), legacy)
        assertEquals(PersistedChatMessage.Delivery.SENT, decoded.delivery)
    }

    // MARK: - Structured assistant fields (PR: structured ChatMessage)

    @Test
    fun assistantRowWithThinkingRoundtrips() {
        // Mirrors the iOS `PersistedChatMessage.thoughtProcess` /
        // `thoughtSummary` fields. Empty / missing fields stay null
        // so a legacy row deserialises cleanly.
        val msg = PersistedChatMessage(
            id = "m-thinking",
            role = PersistedChatMessage.Role.ASSISTANT,
            content = "The answer is 42.",
            timestampMillis = 100L,
            thoughtProcess = "Let me think about this carefully...",
            thoughtSummary = "Picking the right constant",
        )
        val encoded = json.encodeToString(PersistedChatMessage.serializer(), msg)
        val decoded = json.decodeFromString(PersistedChatMessage.serializer(), encoded)
        assertEquals(msg, decoded)
        assertEquals("Let me think about this carefully...", decoded.thoughtProcess)
        assertEquals("Picking the right constant", decoded.thoughtSummary)
    }

    @Test
    fun assistantRowWithToolStepsRoundtrips() {
        val msg = PersistedChatMessage(
            id = "m-tools",
            role = PersistedChatMessage.Role.ASSISTANT,
            content = "Here's what I found.",
            timestampMillis = 200L,
            toolSteps = listOf(
                PersistedToolStep(
                    id = "t-1",
                    name = "web_search",
                    summary = "Searched the web for \"swift regex\"",
                    detail = "3 sources",
                ),
                PersistedToolStep(
                    id = "t-2",
                    name = "wikipedia",
                    summary = "Pulled the Wikipedia article on regex",
                ),
            ),
        )
        val encoded = json.encodeToString(PersistedChatMessage.serializer(), msg)
        val decoded = json.decodeFromString(PersistedChatMessage.serializer(), encoded)
        assertEquals(msg, decoded)
        assertEquals(2, decoded.toolSteps.size)
        assertEquals("web_search", decoded.toolSteps[0].name)
        assertEquals("3 sources", decoded.toolSteps[0].detail)
        assertNull(decoded.toolSteps[1].detail)
    }

    @Test
    fun legacyAssistantRowsWithoutStructuredFieldsDefaultToEmpty() {
        // A pre-structured-fields JSON blob (older installs) must
        // deserialise with `thoughtProcess = null`, `thoughtSummary = null`,
        // `toolSteps = []`. The chat view layer handles these
        // gracefully (it falls back to re-extracting the body).
        val legacy = """
            {"id":"a-1","role":"assistant","content":"hello","timestampMillis":1}
        """.trimIndent()
        val decoded = json.decodeFromString(PersistedChatMessage.serializer(), legacy)
        assertNull(decoded.thoughtProcess)
        assertNull(decoded.thoughtSummary)
        assertTrue(decoded.toolSteps.isEmpty())
    }
}
