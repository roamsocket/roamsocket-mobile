package app.roamsocket.core.providers

/**
 * Returns the right [ModelProvider] for a given [ProviderId], or null if
 * no built-in client exists (e.g. on-device Metal, which has no Android
 * equivalent yet). Mirrors the iOS `ProviderRegistry` lookup.
 */
public object ProviderRegistry {
    public fun client(id: ProviderId, http: HTTPClient = OkHttpHTTPClient()): ModelProvider? =
        when (id) {
            ProviderId.Anthropic -> AnthropicProvider(id = id, http = http)
            ProviderId.OpenAI, ProviderId.Groq, ProviderId.OpenRouter,
            ProviderId.XAI, ProviderId.Mistral, ProviderId.MiniMax ->
                OpenAICompatibleProvider(id = id, http = http)
            ProviderId.Google -> GoogleProvider(id = id, http = http)
            ProviderId.LocalMetal -> null // no Android equivalent
            is ProviderId.Custom -> null // resolved by `clientFor(custom)`
        }

    /** Resolve a [ProviderId.Custom] using the user's persisted base URL/style. */
    public fun clientFor(custom: CustomProvider, http: HTTPClient = OkHttpHTTPClient()): ModelProvider {
        return when (custom.style) {
            CustomProviderStyle.OPENAI ->
                OpenAICompatibleProvider(id = custom.providerID, http = http, baseURL = custom.baseURL)
            CustomProviderStyle.ANTHROPIC ->
                AnthropicProvider(id = custom.providerID, http = http, baseURL = custom.baseURL)
        }
    }
}
