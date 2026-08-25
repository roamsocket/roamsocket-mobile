package app.roamsocket.core.providers

import app.roamsocket.core.protocol.Effort
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * OpenAI Chat Completions provider — used for OpenAI itself, Groq,
 * OpenRouter, xAI, Mistral, MiniMax, and any custom `OPENAI`-style endpoint.
 * Mirrors `ios/AnyProvCore/.../OpenAICompatibleProvider.swift`.
 */
public class OpenAICompatibleProvider(
    override val id: ProviderId,
    private val http: HTTPClient = OkHttpHTTPClient(),
    private val baseURL: String = id.defaultOpenAIBaseURL(),
) : ModelProvider {

    /** Test-visible accessor for the resolved base URL. */
    internal fun baseURLForTest(): String = baseURL

    @Serializable
    private data class ModelList(val data: List<Model> = emptyList()) {
        /**
         * Wire shape for the `/v1/models` endpoint.
         *
         * OpenRouter enriches the response with `architecture.input_modalities`
         * (an array containing strings like `"text"`, `"image"`, `"audio"`,
         * `"video"`, `"pdf"`) — the source of truth for vision capability.
         * Other OpenAI-compatible hosts (OpenAI, Groq, xAI, Mistral, MiniMax)
         * just return `{"id": "..."}` so the `architecture` field is
         * `null` and we fall back to the id-based heuristic.
         */
        @Serializable
        data class Model(
            val id: String,
            val architecture: Architecture? = null,
        ) {
            @Serializable
            data class Architecture(
                @SerialName("input_modalities")
                val inputModalities: List<String> = emptyList(),
            )
        }
    }

    override suspend fun listModels(apiKey: String): List<AIModel> {
        if (apiKey.isEmpty()) throw ProviderError.MissingKey
        val response = http.data(
            ProviderHTTP.get(
                url = "$baseURL/models",
                headers = mapOf("Authorization" to "Bearer $apiKey"),
            ),
        )
        return runCatching {
            val list = Json { ignoreUnknownKeys = true }
                .decodeFromString(ModelList.serializer(), response.body)
            list.data.map { m ->
                val supportsVision = when {
                    // OpenRouter + similar: trust the API's input_modalities.
                    m.architecture != null -> m.architecture.inputModalities.any { it.equals("image", ignoreCase = true) }
                    // Fallback: per-provider id heuristic.
                    else -> ModelCapabilities.supportsVisionByHeuristic(id, m.id)
                }
                AIModel(
                    provider = id,
                    modelID = m.id,
                    displayName = AIModel.prettifiedDisplayName(m.id, id),
                    supportsVision = supportsVision,
                )
            }
        }.getOrElse { throw ProviderError.Decoding(it.message ?: it.javaClass.simpleName) }
    }

    @Serializable
    private data class ChatRequest(
        val model: String,
        val messages: List<JsonObject>,
        val stream: Boolean = false,
        val temperature: Double? = null,
        val plugins: List<Plugin>? = null,
    )

    @Serializable
    private data class Plugin(
        val id: String,
        val max_results: Int? = null,
        val search_prompt: String? = null,
    )

    @Serializable
    private data class ChatResponse(val choices: List<Choice> = emptyList()) {
        @Serializable
        data class Choice(val message: Message) {
            @Serializable
            data class Message(val content: String? = null)
        }
    }

    override suspend fun chat(
        model: String,
        apiKey: String,
        messages: List<ProviderChatMessage>,
        effort: Effort?,
    ): String {
        if (apiKey.isEmpty()) throw ProviderError.MissingKey
        val body = ChatRequest(
            model = model,
            messages = messages.map(::toOpenAIMessage),
        )
        val response = http.data(
            ProviderHTTP.post(
                url = "$baseURL/chat/completions",
                headers = mapOf(
                    "Authorization" to "Bearer $apiKey",
                    "content-type" to "application/json",
                ),
                body = Json.encodeToString(ChatRequest.serializer(), body),
            ),
        )
        return try {
            val parsed = Json { ignoreUnknownKeys = true }
                .decodeFromString(ChatResponse.serializer(), response.body)
            val content = parsed.choices.firstOrNull()?.message?.content
            if (content.isNullOrEmpty()) {
                // An HTTP 200 with no choices (or an empty content field) is a
                // provider-side refusal / safety block / upstream outage. Surface
                // it as a real error so the user sees a message instead of an
                // empty assistant bubble that looks like a successful reply.
                throw ProviderError.Http(200, "Provider returned no choices or empty content.")
            }
            content
        } catch (e: ProviderError) {
            throw e
        } catch (e: Throwable) {
            throw ProviderError.Decoding(e.message ?: e.javaClass.simpleName)
        }
    }

    /**
     * Stream the OpenAI-compatible SSE stream, emitting text deltas.
     * Mirrors the non-streaming `chat()` path with the same request shape,
     * plus `stream: true` and SSE `data:` line parsing.
     */
    override suspend fun chatStream(
        model: String,
        apiKey: String,
        messages: List<ProviderChatMessage>,
        effort: Effort?,
        webSearchQuery: String?,
    ): Flow<String> {
        if (apiKey.isEmpty()) throw ProviderError.MissingKey

        // OpenRouter: native web search plugin.
        // Mirrors iOS `OpenAICompatibleProvider.chat` which passes the `web`
        // plugin for OpenRouter when web search is active.
        val plugins: List<Plugin>? = if (id == ProviderId.OpenRouter && !webSearchQuery.isNullOrEmpty()) {
            listOf(
                Plugin(
                    id = "web",
                    max_results = 5,
                    search_prompt = webSearchQuery,
                ),
            )
        } else null

        val body = buildJsonObject {
            put("model", model)
            put("messages", buildJsonArray {
                for (msg in messages.map(::toOpenAIMessage)) { add(msg) }
            })
            put("stream", true)
            plugins?.let { ps ->
                put("plugins", buildJsonArray {
                    for (p in ps) {
                        add(buildJsonObject {
                            put("id", p.id)
                            p.max_results?.let { put("max_results", it) }
                            p.search_prompt?.let { put("search_prompt", it) }
                        })
                    }
                })
            }
        }

        return flow {
            http.streamEvents(
                ProviderHTTP.post(
                    url = "$baseURL/chat/completions",
                    headers = mapOf(
                        "Authorization" to "Bearer $apiKey",
                        "content-type" to "application/json",
                    ),
                    body = body.toString(),
                ),
            ).collect { line ->
                // SSE line: "data: {...}" or "data: [DONE]"
                if (line == "[DONE]") return@collect
                runCatching {
                    val json = Json.parseToJsonElement(line).jsonObject
                    val choices = json["choices"]
                    if (choices is JsonArray && choices.isNotEmpty()) {
                        val delta = choices[0].jsonObject
                            .get("delta")?.jsonObject
                        val content = delta?.get("content")?.jsonPrimitive?.content
                        if (!content.isNullOrEmpty()) {
                            emit(content)
                        }
                    }
                }
            }
        }
    }

    private fun toOpenAIMessage(m: ProviderChatMessage): JsonObject = buildJsonObject {
        put("role", m.role.name.lowercase())
        if (m.images.isEmpty()) {
            put("content", m.content)
        } else {
            val parts = buildJsonArray {
                for (image in m.images) {
                    add(buildJsonObject {
                        put("type", "image_url")
                        put("image_url", buildJsonObject { put("url", image.dataURL) })
                    })
                }
                val text = m.content.trim()
                add(buildJsonObject {
                    put("type", "text")
                    put("text", if (text.isEmpty()) "Analyze this image." else text)
                })
            }
            put("content", parts)
        }
    }
}

private fun ProviderId.defaultOpenAIBaseURL(): String = when (this) {
    ProviderId.OpenAI -> "https://api.openai.com/v1"
    ProviderId.Groq -> "https://api.groq.com/openai/v1"
    ProviderId.OpenRouter -> "https://openrouter.ai/api/v1"
    ProviderId.XAI -> "https://api.x.ai/v1"
    ProviderId.Mistral -> "https://api.mistral.ai/v1"
    // Mirrors `desktop-server/src/proxy/index.ts` and
    // `ios/AnyProvCore/Sources/AnyProvCore/Providers/OpenAICompatibleProvider.swift`.
    // The Android URL was historically `api.minimax.chat` which does NOT host the
    // MiniMax LLM API and always returns 401 — keep all three surfaces in lockstep.
    ProviderId.MiniMax -> "https://api.minimax.io/v1"
    else -> error("Provider $this does not default to an OpenAI-compatible base URL")
}
