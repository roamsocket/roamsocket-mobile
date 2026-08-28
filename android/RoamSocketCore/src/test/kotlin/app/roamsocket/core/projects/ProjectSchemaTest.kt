package app.roamsocket.core.projects

import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ProviderId
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectSchemaTest {

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        prettyPrint = false
    }

    @Test
    fun projectItemRoundTripsThroughJson() {
        val original = ProjectItem(
            id = "11111111-1111-1111-1111-111111111111",
            name = "RoamSocket Mobile",
            updatedAtMillis = 1_700_000_000_000L,
            instructions = "Think step by step.",
            memory = "• Likes dark mode\n• Prefers concise replies",
            memoryUpdatedAtMillis = 1_700_000_001_000L,
        )
        val encoded = json.encodeToString(original)
        // Spot-check the JSON key names match the iOS Codable shape.
        assertTrue("missing id", encoded.contains("\"id\":\"11111111"))
        assertTrue("missing name", encoded.contains("\"name\":\"RoamSocket Mobile\""))
        assertTrue("missing updatedAtMillis", encoded.contains("\"updatedAtMillis\":1700000000000"))
        assertTrue("missing instructions", encoded.contains("\"instructions\":\"Think step by step.\""))
        assertTrue("missing memory", encoded.contains("\"memory\":\""))
        assertTrue("missing memoryUpdatedAtMillis", encoded.contains("\"memoryUpdatedAtMillis\":1700000001000"))
        val decoded = json.decodeFromString<ProjectItem>(encoded)
        assertEquals(original, decoded)
    }

    @Test
    fun projectItemDefaultsAreAppliedOnDecode() {
        // A JSON body with only the required fields should decode with
        // the documented defaults (empty instructions, empty memory,
        // null memoryUpdatedAtMillis).
        val body = """
            {"id":"abc","name":"X","updatedAtMillis":42}
        """.trimIndent()
        val decoded = json.decodeFromString<ProjectItem>(body)
        assertEquals("", decoded.instructions)
        assertEquals("", decoded.memory)
        assertNull(decoded.memoryUpdatedAtMillis)
    }

    @Test
    fun projectChatItemRoundTripsThroughJson() {
        val original = ProjectChatItem(
            id = "chat-1",
            title = "SSE vs WebSockets",
            lastMessageAtMillis = 1_700_000_000_000L,
            messages = listOf(
                PersistedChatMessage(
                    id = "u-1",
                    role = PersistedChatMessage.Role.USER,
                    content = "What is SSE?",
                    timestampMillis = 1_700_000_000_000L,
                ),
            ),
            isArchived = false,
            selectedModel = AIModel(
                provider = ProviderId.Anthropic,
                modelID = "claude-3-5-sonnet-20241022",
                displayName = "Claude 3.5 Sonnet",
            ),
            titleIsUserEdited = false,
            didAutoTitle = true,
            autoTitleAtUserCount = 1,
        )
        val encoded = json.encodeToString(original)
        assertTrue("missing selectedModel", encoded.contains("\"selectedModel\":"))
        assertTrue("missing modelID", encoded.contains("\"modelID\":\"claude-3-5-sonnet-20241022\""))
        val decoded = json.decodeFromString<ProjectChatItem>(encoded)
        assertEquals(original, decoded)
    }
}
