package app.roamsocket.core.providers

/**
 * Static fallback list of known-good models per provider. Mirrors
 * `ios/AnyProvCore/.../ModelCatalog.swift`. Used when the user has not
 * yet listed live models from the provider API.
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
}
