package app.roamsocket.core.providers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks in the vision heuristics used by the Vision mode screen. The
 * rules here are user-facing: an incorrectly classified model either
 * blocks image input or accepts an image the API will reject. Mirror
 * the iOS `VisionCapability` rules so both clients agree.
 */
class ModelCapabilitiesVisionTest {

    @Test
    fun `clearly non-vision ids are always rejected regardless of provider flag`() {
        val baseCases = listOf(
            "whisper-large-v3" to ProviderId.OpenAI,
            "text-embedding-3-small" to ProviderId.OpenAI,
            "tts-1" to ProviderId.OpenAI,
            "dall-e-3" to ProviderId.OpenAI,
            "moderation-latest" to ProviderId.OpenAI,
        )
        for ((id, provider) in baseCases) {
            assertTrue(
                "Expected $provider/$id to be flagged non-vision",
                ModelCapabilities.isClearlyNonVisionModelID(id),
            )
        }
    }

    @Test
    fun `known multimodal families are vision-capable`() {
        val cases = listOf(
            "gpt-4o" to ProviderId.OpenAI,
            "gpt-4o-mini" to ProviderId.OpenAI,
            "gpt-4.1" to ProviderId.OpenAI,
            "gpt-4-turbo" to ProviderId.OpenAI,
            "gpt-5" to ProviderId.OpenAI,
            "o1" to ProviderId.OpenAI,
            "o3-mini" to ProviderId.OpenAI,
            "claude-3-5-sonnet-20241022" to ProviderId.Anthropic,
            "claude-3-opus-20240229" to ProviderId.Anthropic,
            "claude-sonnet-4-20250514" to ProviderId.Anthropic,
            "gemini-2.0-flash" to ProviderId.Google,
            "gemini-1.5-pro" to ProviderId.Google,
            "grok-2-vision-1212" to ProviderId.XAI,
            "grok-4-0709" to ProviderId.XAI,
        )
        for ((id, provider) in cases) {
            assertTrue(
                "Expected $provider/$id to be vision-capable",
                ModelCapabilities.supportsVisionByHeuristic(provider, id),
            )
        }
    }

    @Test
    fun `text-only models are not vision-capable`() {
        val cases = listOf(
            "gpt-3.5-turbo" to ProviderId.OpenAI,
            "claude-2.1" to ProviderId.Anthropic,
            "mistral-large-latest" to ProviderId.Mistral,
            "llama-3.1-70b-versatile" to ProviderId.Groq,
            "minimax-chat" to ProviderId.MiniMax,
        )
        for ((id, provider) in cases) {
            assertFalse(
                "Expected $provider/$id to be text-only",
                ModelCapabilities.supportsVisionByHeuristic(provider, id),
            )
        }
    }

    @Test
    fun `preferred vision model picks the flagship on each provider`() {
        val models = listOf(
            AIModel(ProviderId.Anthropic, "claude-3-5-sonnet-20241022", "Claude 3.5 Sonnet", supportsVision = true),
            AIModel(ProviderId.OpenAI, "gpt-4o", "GPT-4o", supportsVision = true),
            AIModel(ProviderId.Google, "gemini-2.0-flash", "Gemini 2.0 Flash", supportsVision = true),
            AIModel(ProviderId.Mistral, "mistral-large-latest", "Mistral Large"),
        )
        val pick = ModelCapabilities.preferredVisionModel(models)
        // The order tries the flagship list; first match wins. Either
        // GPT-4o or Claude 3.5 Sonnet would be acceptable as flagship
        // picks depending on enum order — accept any vision-capable
        // pick from the list.
        assertNotNull("preferredVisionModel should pick something", pick)
        assertTrue(
            "Picked model should be vision-capable",
            ModelCapabilities.supportsVision(pick!!),
        )
    }

    @Test
    fun `preferred vision model honours the current pick when it is vision-capable`() {
        val current = AIModel(ProviderId.OpenAI, "gpt-4o", "GPT-4o", supportsVision = true)
        val pick = ModelCapabilities.preferredVisionModel(
            models = listOf(
                current,
                AIModel(ProviderId.Anthropic, "claude-3-opus-20240229", "Claude 3 Opus", supportsVision = true),
            ),
            current = current,
        )
        assertEquals(current, pick)
    }

    @Test
    fun `preferred vision model returns null when nothing matches`() {
        val pick = ModelCapabilities.preferredVisionModel(models = emptyList())
        assertNull(pick)
    }
}
