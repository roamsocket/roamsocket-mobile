package app.roamsocket.core.providers

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * Static fallback list + live catalog fetcher.
 *
 * Mirrors `ios/AnyProvCore/.../ModelCatalog.swift`. The static [defaults]
 * are used when the user has not yet listed live models (offline
 * cold-start, no API key yet, or a provider errored). [fetchAll] is the
 * dynamic path: it asks every provider that has a key for its model
 * list, in parallel, and returns per-provider results (including
 * failures, surfaced as the [ProviderResult.error] field).
 */
public object ModelCatalog {

    public val defaults: List<AIModel> = listOf(
        // Anthropic — Claude 3+ family is multimodal.
        AIModel(ProviderId.Anthropic, "claude-3-5-sonnet-20241022", "Claude 3.5 Sonnet", supportsVision = true),
        AIModel(ProviderId.Anthropic, "claude-3-5-haiku-20241022", "Claude 3.5 Haiku", supportsVision = true),
        AIModel(ProviderId.Anthropic, "claude-3-opus-20240229", "Claude 3 Opus", supportsVision = true),
        // OpenAI — gpt-4o / o1 are multimodal; legacy gpt-3.5/gpt-4 are text-only.
        AIModel(ProviderId.OpenAI, "gpt-4o", "GPT-4o", supportsVision = true),
        AIModel(ProviderId.OpenAI, "gpt-4o-mini", "GPT-4o mini", supportsVision = true),
        AIModel(ProviderId.OpenAI, "o1", "o1", supportsVision = true),
        AIModel(ProviderId.OpenAI, "o1-mini", "o1 mini", supportsVision = true),
        // Google — Gemini 1.5/2.0/2.5 are multimodal; embedding/text-only models are not.
        AIModel(ProviderId.Google, "gemini-2.0-flash", "Gemini 2.0 Flash", supportsVision = true),
        AIModel(ProviderId.Google, "gemini-1.5-pro", "Gemini 1.5 Pro", supportsVision = true),
        // Groq — text-only inference.
        AIModel(ProviderId.Groq, "llama-3.1-70b-versatile", "Llama 3.1 70B Versatile"),
        AIModel(ProviderId.Groq, "llama-3.1-8b-instant", "Llama 3.1 8B Instant"),
        // OpenRouter — pinned examples; live listing fills the rest.
        AIModel(ProviderId.OpenRouter, "openai/gpt-4o", "GPT-4o (OpenRouter)", supportsVision = true),
        AIModel(ProviderId.OpenRouter, "anthropic/claude-3.5-sonnet", "Claude 3.5 Sonnet (OpenRouter)", supportsVision = true),
        // xAI — Grok 2 Vision is multimodal; base Grok 2 is text-only.
        AIModel(ProviderId.XAI, "grok-2-vision-1212", "Grok 2 Vision", supportsVision = true),
        AIModel(ProviderId.XAI, "grok-2", "Grok 2"),
        // Mistral — text-only chat by default; Pixtral is the vision line.
        AIModel(ProviderId.Mistral, "mistral-large-latest", "Mistral Large"),
        AIModel(ProviderId.Mistral, "codestral-latest", "Codestral"),
        // MiniMax — text-only in this catalog (no vision models in the default set).
        AIModel(ProviderId.MiniMax, "minimax-chat", "MiniMax Chat"),
    )

    /** Defaults filtered to a single provider, sorted by display name. */
    public fun defaultsFor(provider: ProviderId): List<AIModel> =
        defaults.filter { it.provider == provider }.sortedBy { it.displayName }

    /**
     * Per-provider outcome of a catalog fetch. [models] is the live
     * listing (possibly empty if the provider errored); [error] is a
     * human-readable message when the fetch failed, null otherwise.
     */
    public data class ProviderResult(
        val provider: ProviderId,
        val models: List<AIModel>,
        val error: String? = null,
    )

    /**
     * Fetch models from every provider in [keys] that has a non-empty
     * key, concurrently. Providers with no client registered (e.g.
     * on-device Metal on Android) or no key are skipped. The returned
     * list is in the same order as the input.
     *
     * Failures are captured per-provider (not thrown), so the UI can
     * show one provider's models even if another 500s.
     */
    public suspend fun fetchAll(
        keys: Map<ProviderId, String>,
        http: HTTPClient = OkHttpHTTPClient(),
    ): List<ProviderResult> = coroutineScope {
        val configured = keys.filter { it.value.isNotEmpty() }
        configured.entries.map { (id, key) ->
            async {
                val client = ProviderRegistry.client(id, http)
                if (client == null) {
                    ProviderResult(id, models = emptyList(), error = "No client for $id")
                } else {
                    try {
                        val models = client.listModels(key)
                        ProviderResult(id, models = models)
                    } catch (e: Throwable) {
                        ProviderResult(
                            id,
                            models = emptyList(),
                            error = e.message ?: e.javaClass.simpleName,
                        )
                    }
                }
            }
        }.awaitAll()
    }
}

/**
 * Centralised per-model capability heuristics. Providers that *don't*
 * expose capability flags in their `/models` API (Anthropic, OpenAI,
 * Google, Groq, xAI, Mistral, MiniMax) call into here so the answer
 * is consistent across the app. OpenRouter parses the actual
 * `architecture.input_modalities` field from its API and bypasses
 * the heuristic.
 *
 * The heuristics are deliberately enumerated — new providers must
 * make a deliberate decision rather than silently defaulting to
 * vision-capable.
 */
public object ModelCapabilities {
    /**
     * Returns `true` when [modelID] is plausibly multimodal for the
     * given [provider]. Heuristic — false negatives are OK (the model
     * is treated as text-only), false positives are user-facing so
     * keep this conservative.
     */
    public fun supportsVisionByHeuristic(provider: ProviderId, modelID: String): Boolean {
        val id = modelID.lowercase()
        // Universal signals — embeddings, TTS, transcription are text-free.
        if (id.contains("embedding") || id.contains("whisper") ||
            id.contains("tts") || id.contains("dall-e") || id.contains("moderation")) {
            return false
        }
        return when (provider) {
            ProviderId.Anthropic -> {
                // Claude 2 is text-only. Claude 3+ all support vision.
                id.contains("claude-3") || id.contains("claude-4") ||
                    id.contains("claude-sonnet-4") || id.contains("claude-opus-4")
            }
            ProviderId.OpenAI -> {
                id.contains("gpt-4o") || id.contains("gpt-4.1") ||
                    id.contains("gpt-4-turbo") || id.contains("gpt-4-vision") ||
                    id.contains("gpt-5") || id.contains("vision") ||
                    id.startsWith("o1") || id.startsWith("o3") || id.startsWith("o4") ||
                    id.contains("chatgpt-4o")
            }
            ProviderId.Google -> {
                // Gemini 1.5 / 2.0 / 2.5 all support images. text-embedding-* / *-text-* don't.
                id.contains("gemini") && !id.contains("embedding")
            }
            ProviderId.XAI ->
                // xAI Grok multimodal family — any grok-* id that is
                // not the text-only or image-gen variant accepts
                // image input. Mirrors the iOS `VisionCapability`.
                (id.contains("grok") && !id.contains("text") && !id.contains("imagine")) ||
                    id.contains("vision")
            ProviderId.OpenRouter -> {
                // Best-effort: most OpenRouter models follow the same naming as
                // the upstream provider. The live `architecture.input_modalities`
                // field takes precedence when present.
                id.contains("vision") || id.contains("vl") || id.contains("vlm") ||
                    id.contains("gpt-4o") || id.contains("claude-3") || id.contains("claude-4") ||
                    id.contains("gemini") || id.contains("pixtral") ||
                    id.startsWith("o1") || id.startsWith("o3") || id.startsWith("o4")
            }
            ProviderId.LocalMetal -> true
            is ProviderId.Custom -> true
            ProviderId.Groq, ProviderId.Mistral, ProviderId.MiniMax -> false
        }
    }

    /**
     * Models that never accept images (embeddings, audio, image-gen, …).
     * Mirrors the iOS `VisionCapability.isClearlyNonVisionModelID` so both
     * clients filter out the same junk ids when listing.
     */
    public fun isClearlyNonVisionModelID(modelID: String): Boolean {
        val id = modelID.lowercase()
        return id.contains("whisper") ||
            id.contains("embed") ||
            id.contains("tts") ||
            id.contains("moderation") ||
            id.contains("transcri") ||
            id.contains("dall-e") ||
            id.contains("tts-") ||
            id.contains("realtime") ||
            id.contains("text-embedding") ||
            id.contains("rerank")
    }

    /**
     * Pick the best vision-capable model for the Vision mode entry point.
     * Honors the current selection if it is already a vision model, else
     * falls back to a known-flagship id, then to the first vision-capable
     * entry. Mirrors the iOS `VisionCapability.preferredVisionModel`.
     *
     * @param isVision Override for callers that compute vision a different
     *   way (e.g. custom provider's `supportsVision` flag). Defaults to the
     *   [supportsVisionByHeuristic] + [isClearlyNonVisionModelID] combo.
     */
    public fun preferredVisionModel(
        models: List<AIModel>,
        current: AIModel? = null,
        isVision: (AIModel) -> Boolean = { supportsVision(it) },
    ): AIModel? {
        if (current != null && isVision(current)) return current
        val vision = models.filter(isVision)
        val preferred = listOf(
            // Cloud flagships
            "gpt-5", "gpt-4o", "gpt-4.1", "claude-sonnet-4", "claude-opus",
            "claude-sonnet", "grok-4", "grok-2-vision", "pixtral",
        )
        for (needle in preferred) {
            val match = vision.firstOrNull { it.modelID.lowercase().contains(needle) }
            if (match != null) return match
        }
        return vision.firstOrNull()
    }

    /**
     * Convenience — same as [AIModel.supportsVision] but called on the
     * model directly. Combines the heuristic with the negative filter
     * (so e.g. an OpenAI `gpt-4-vision-preview` is fine but a `whisper-*`
     * is always text-only).
     */
    public fun supportsVision(model: AIModel): Boolean {
        if (model.supportsVision) {
            if (isClearlyNonVisionModelID(model.modelID)) return false
            return true
        }
        return supportsVisionByHeuristic(model.provider, model.modelID)
    }
}
