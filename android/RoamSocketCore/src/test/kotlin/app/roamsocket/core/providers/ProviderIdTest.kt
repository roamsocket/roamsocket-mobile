package app.roamsocket.core.providers

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderIdTest {

    private val json = Json { encodeDefaults = true }

    @Test
    fun `built-in roundtrips through serializer`() {
        for (id in ProviderId.BUILT_IN) {
            val encoded = json.encodeToString(ProviderId.Serializer, id)
            val decoded = json.decodeFromString(ProviderId.Serializer, encoded)
            assertEquals(id, decoded)
        }
    }

    @Test
    fun `anthropic singleton roundtrips through serializer`() {
        val id: ProviderId = ProviderId.Anthropic
        val encoded = json.encodeToString(ProviderId.Serializer, id)
        assertEquals("\"anthropic\"", encoded)
        val decoded = json.decodeFromString(ProviderId.Serializer, encoded)
        assertEquals(id, decoded)
    }

    @Test
    fun `custom provider serialises as custom slug`() {
        val id = ProviderId.Custom("my-ollama")
        val encoded = json.encodeToString(ProviderId.Serializer, id)
        assertEquals("\"custom:my-ollama\"", encoded)
        val decoded = json.decodeFromString(ProviderId.Serializer, encoded)
        assertEquals(id, decoded)
    }

    @Test
    fun `fromRawValue handles legacy aliases`() {
        assertEquals(ProviderId.MiniMax, ProviderId.fromRawValue("minimax"))
        assertEquals(ProviderId.MiniMax, ProviderId.fromRawValue("mini-max"))
        assertEquals(ProviderId.LocalMetal, ProviderId.fromRawValue("local-metal"))
        assertEquals(ProviderId.LocalMetal, ProviderId.fromRawValue("localMetal"))
    }

    @Test
    fun `prettifiedDisplayName converts claude and gpt correctly`() {
        // Tokens separated by `-` (e.g. "3-5" → "3 5") stay as separate
        // words — mirrors the iOS behavior. The version "4o" is preserved.
        assertEquals("Claude 3 5 Sonnet 20241022", AIModel.prettifiedDisplayName("claude-3-5-sonnet-20241022"))
        assertEquals("GPT 4o", AIModel.prettifiedDisplayName("gpt-4o"))
        assertEquals("GPT 4o Mini", AIModel.prettifiedDisplayName("gpt-4o-mini"))
        assertEquals("DeepSeek R1", AIModel.prettifiedDisplayName("deepseek-r1"))
    }

    @Test
    fun `prettifiedDisplayName drops openrouter org prefix`() {
        val pretty = AIModel.prettifiedDisplayName("openai/gpt-4o", ProviderId.OpenRouter)
        assertEquals("GPT 4o", pretty)
    }
}
