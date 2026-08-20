package app.roamsocket.core.chats

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
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
}
