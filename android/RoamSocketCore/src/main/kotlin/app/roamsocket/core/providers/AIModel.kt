package app.roamsocket.core.providers

import kotlinx.serialization.Serializable

/**
 * A single model exposed by a provider. Mirrors
 * `ios/AnyProvCore/.../AIModel.swift`.
 */
@Serializable
public data class AIModel(
    val provider: ProviderId,
    /** Provider-native model id, e.g. `gpt-4o` or `gemini-2.0-flash`. */
    val modelID: String,
    val displayName: String,
    val contextWindow: Int? = null,
    /** Vendor / organization the model belongs to (OpenRouter), e.g. "OpenAI". */
    val organization: String? = null,
    /** True when the model is free to use (OpenRouter `is_free`). */
    val isFree: Boolean? = null,
    /**
     * True when the model can accept image attachments (vision / multimodal
     * input). Populated by each provider's [ModelProvider.listModels]
     * using the provider API where possible (OpenRouter's
     * `architecture.input_modalities`) and a model-id heuristic as a
     * fallback for providers that don't expose the flag (Anthropic,
     * OpenAI, Google).
     *
     * Drives the chat's inline error: when the user attaches an image
     * to a non-vision model we show a contextual hint above the input
     * bar (see `ChatViewModel.computeInlineError`).
     */
    val supportsVision: Boolean = false,
) {
    /** Stable identity across providers, e.g. `anthropic/claude-…`. */
    val id: String get() = "${provider.rawValue}/$modelID"

    public companion object {
        /** Display-name prettifier used in pickers. Same algorithm as iOS. */
        public fun prettifiedDisplayName(raw: String, provider: ProviderId? = null): String {
            var id = raw
            if (provider is ProviderId.OpenRouter) {
                val slash = id.indexOf('/')
                if (slash >= 0) id = id.substring(slash + 1)
            }
            val tokens = id
                .replace("~", " ")
                .replace("_", " ")
                .replace("/", " ")
                .replace("-", " ")
                .split(' ', '\t')
                .filter { it.isNotBlank() }
            if (tokens.isEmpty()) return raw
            return tokens.joinToString(" ") { prettifyToken(it) }
        }

        private val brandOverrides = mapOf(
            "deepseek" to "DeepSeek",
            "openai" to "OpenAI",
            "xai" to "xAI",
            "moonshot" to "Moonshot",
            "minimax" to "MiniMax",
            "qwen" to "Qwen",
            "gemma" to "Gemma",
            "phi" to "Phi",
            "glm" to "GLM",
            "grok" to "Grok",
            "mistral" to "Mistral",
            "mistralai" to "Mistral AI",
            "ministral" to "Ministral",
            "llama" to "Llama",
            "claude" to "Claude",
            "gemini" to "Gemini",
            "olmo" to "OLMo",
            "kimi" to "Kimi",
            "yi" to "Yi",
            "dbrx" to "DBRX",
            "falcon" to "Falcon",
            "command" to "Command",
            "jamba" to "Jamba",
            "granite" to "Granite",
            "nemotron" to "Nemotron",
            "tulu" to "Tulu",
            "hermes" to "Hermes",
            "zephyr" to "Zephyr",
            "openchat" to "OpenChat",
            "t5" to "T5",
            "mpt" to "MPT",
            "codegeex" to "CodeGeeX",
            "codestral" to "Codestral",
            "devstral" to "Devstral",
            "palm" to "PaLM",
            "baichuan" to "Baichuan",
            "internlm" to "InternLM",
            "zhipu" to "Zhipu",
            "vllm" to "vLLM",
            "gpt" to "GPT",
        )

        private fun prettifyToken(token: String): String {
            val lower = token.lowercase()
            brandOverrides[lower]?.let { return it }
            // "4o" / "4.5" etc — keep as-is.
            if (token.matches(Regex("""^\d+o$"""))) return token
            // "70b" → "70B".
            if (token.matches(Regex("""^\d+(\.\d+)?[bBmMkK]?$"""))) return token.uppercase()
            if (token.length <= 3 && token == lower) return token.uppercase()
            return token.replaceFirstChar { it.uppercase() }
        }
    }
}

/** HTTP shape used for listing models and chat completions. */
@Serializable
public enum class CustomProviderStyle {
    /** OpenAI Chat Completions: `GET {base}/models`, `POST {base}/chat/completions`. */
    OPENAI,
    /** Anthropic Messages: `GET {base}/models`, `POST {base}/messages`. */
    ANTHROPIC,
    ;

    public val displayName: String
        get() = when (this) {
            OPENAI -> "OpenAI-compatible"
            ANTHROPIC -> "Anthropic Messages"
        }

    public val detail: String
        get() = when (this) {
            OPENAI -> "POST {base}/chat/completions · GET {base}/models · Bearer auth"
            ANTHROPIC -> "POST {base}/messages · GET {base}/models · x-api-key auth"
        }
}

/** A user-defined provider endpoint (BYO base URL). */
@Serializable
public data class CustomProvider(
    val id: String,
    val label: String,
    /** Base URL including the version segment, e.g. `https://host/v1`. */
    val baseURL: String,
    val style: CustomProviderStyle = CustomProviderStyle.OPENAI,
    /** When true, models are treated as vision-capable. */
    val supportsVision: Boolean = false,
) {
    val providerID: ProviderId get() = ProviderId.Custom(id)
}
