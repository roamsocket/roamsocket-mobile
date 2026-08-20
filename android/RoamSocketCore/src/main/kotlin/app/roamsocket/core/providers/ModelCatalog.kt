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
        // Anthropic
        AIModel(ProviderId.Anthropic, "claude-3-5-sonnet-20241022", "Claude 3.5 Sonnet"),
        AIModel(ProviderId.Anthropic, "claude-3-5-haiku-20241022", "Claude 3.5 Haiku"),
        // OpenAI
        AIModel(ProviderId.OpenAI, "gpt-4o", "GPT-4o"),
        AIModel(ProviderId.OpenAI, "gpt-4o-mini", "GPT-4o mini"),
        AIModel(ProviderId.OpenAI, "o1", "o1"),
        AIModel(ProviderId.OpenAI, "o1-mini", "o1 mini"),
        // Google
        AIModel(ProviderId.Google, "gemini-2.0-flash", "Gemini 2.0 Flash"),
        AIModel(ProviderId.Google, "gemini-1.5-pro", "Gemini 1.5 Pro"),
        // Groq
        AIModel(ProviderId.Groq, "llama-3.1-70b-versatile", "Llama 3.1 70B Versatile"),
        AIModel(ProviderId.Groq, "llama-3.1-8b-instant", "Llama 3.1 8B Instant"),
        // OpenRouter — pinned examples; live listing fills the rest.
        AIModel(ProviderId.OpenRouter, "openai/gpt-4o", "GPT-4o (OpenRouter)"),
        AIModel(ProviderId.OpenRouter, "anthropic/claude-3.5-sonnet", "Claude 3.5 Sonnet (OpenRouter)"),
        // xAI
        AIModel(ProviderId.XAI, "grok-2", "Grok 2"),
        // Mistral
        AIModel(ProviderId.Mistral, "mistral-large-latest", "Mistral Large"),
        AIModel(ProviderId.Mistral, "codestral-latest", "Codestral"),
        // MiniMax
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
    ) {
        /** True if the provider errored or returned no models. */
        val isEmpty: Boolean get() = models.isEmpty() && error == null
    }

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
