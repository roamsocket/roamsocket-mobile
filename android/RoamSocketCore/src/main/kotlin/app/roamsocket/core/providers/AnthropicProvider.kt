package app.roamsocket.core.providers

import app.roamsocket.core.protocol.Effort
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Anthropic Messages provider: `GET {base}/models`, `POST {base}/messages`.
 * Also drives user-defined Anthropic-compatible endpoints. Mirrors
 * `ios/AnyProvCore/.../AnthropicProvider.swift`.
 */
public class AnthropicProvider(
    override val id: ProviderId = ProviderId.Anthropic,
    private val http: HTTPClient = OkHttpHTTPClient(),
    private val baseURL: String = "https://api.anthropic.com/v1",
) : ModelProvider {

    @Serializable
    private data class ModelList(val data: List<Model>) {
        @Serializable
        data class Model(
            val id: String,
            @SerialName("display_name") val displayName: String? = null,
        )
    }

    override suspend fun listModels(apiKey: String): List<AIModel> {
        if (apiKey.isEmpty()) throw ProviderError.MissingKey
        val response = http.data(
            ProviderHTTP.get(
                url = "$baseURL/models",
                headers = mapOf(
                    "x-api-key" to apiKey,
                    "anthropic-version" to "2023-06-01",
                ),
            ),
        )
        return runCatching {
            Json { ignoreUnknownKeys = true }.decodeFromString(ModelList.serializer(), response.body)
        }.fold(
            onSuccess = { list ->
                list.data.map { m ->
                    AIModel(
                        provider = id,
                        modelID = m.id,
                        displayName = m.displayName ?: m.id,
                        supportsVision = ModelCapabilities.supportsVisionByHeuristic(id, m.id),
                    )
                }
            },
            onFailure = { throw ProviderError.Decoding(it.message ?: it.javaClass.simpleName) },
        )
    }

    @Serializable
    private data class MessagesRequest(
        val model: String,
        @SerialName("max_tokens") val maxTokens: Int,
        val messages: List<Message>,
        val system: String? = null,
    )

    @Serializable
    private data class Message(val role: String, val content: JsonArray) {
        companion object {
            fun from(message: ProviderChatMessage): Message {
                val blocks = buildJsonArray {
                    for (image in message.images) {
                        add(buildJsonObject {
                            put("type", "image")
                            put("source", buildJsonObject {
                                put("type", "base64")
                                put("media_type", image.mimeType)
                                put("data", image.base64Data)
                            })
                        })
                    }
                    val text = message.content.trim()
                    add(buildJsonObject { put("type", "text"); put("text", if (text.isEmpty()) "Analyze this image." else text) })
                }
                return Message(role = message.role.name.lowercase(), content = blocks)
            }
        }
    }

    @Serializable
    private data class MessagesResponse(val content: List<Content>) {
        @Serializable
        data class Content(val type: String, val text: String? = null)
    }

    override suspend fun chat(
        model: String,
        apiKey: String,
        messages: List<ProviderChatMessage>,
        effort: Effort?,
    ): String {
        if (apiKey.isEmpty()) throw ProviderError.MissingKey
        // Merge all system turns into a single block.
        val system = messages.filter { it.role == ProviderChatMessage.Role.SYSTEM }
            .joinToString("\n\n") { it.content }
            .takeIf { it.isNotEmpty() }
        val turns = messages.filter { it.role != ProviderChatMessage.Role.SYSTEM }
            .map(Message::from)
        val hasImages = messages.any { it.hasImages }
        val body = MessagesRequest(
            model = model,
            maxTokens = if (hasImages) 2048 else 1024,
            messages = turns,
            system = system,
        )
        val response = http.data(
            ProviderHTTP.post(
                url = "$baseURL/messages",
                headers = mapOf(
                    "x-api-key" to apiKey,
                    "anthropic-version" to "2023-06-01",
                    "content-type" to "application/json",
                ),
                body = Json.encodeToString(MessagesRequest.serializer(), body),
            ),
        )
        return runCatching {
            val parsed = Json { ignoreUnknownKeys = true }
                .decodeFromString(MessagesResponse.serializer(), response.body)
            parsed.content.mapNotNull { it.text }.joinToString("\n")
        }.getOrElse { throw ProviderError.Decoding(it.message ?: it.javaClass.simpleName) }
    }

    /**
     * Stream the Anthropic `/messages` SSE stream, emitting text deltas.
     * Each emitted string is an incremental piece of the assistant reply.
     */
    override suspend fun chatStream(
        model: String,
        apiKey: String,
        messages: List<ProviderChatMessage>,
        effort: Effort?,
        webSearchQuery: String?,
    ): Flow<String> {
        if (apiKey.isEmpty()) throw ProviderError.MissingKey
        val system = messages.filter { it.role == ProviderChatMessage.Role.SYSTEM }
            .joinToString("\n\n") { it.content }
            .takeIf { it.isNotEmpty() }
        val turns = messages.filter { it.role != ProviderChatMessage.Role.SYSTEM }
            .map(Message::from)
        val hasImages = messages.any { it.hasImages }
        val body = buildJsonObject {
            put("model", model)
            put("max_tokens", if (hasImages) 2048 else 1024)
            put("messages", buildJsonArray {
                for (t in turns) { add(Json.encodeToJsonElement(Message.serializer(), t)) }
            })
            system?.let { put("system", it) }
            put("stream", true)
        }
        return flow {
            http.streamEvents(
                ProviderHTTP.post(
                    url = "$baseURL/messages",
                    headers = mapOf(
                        "x-api-key" to apiKey,
                        "anthropic-version" to "2023-06-01",
                        "content-type" to "application/json",
                        "accept" to "text/event-stream",
                    ),
                    body = body.toString(),
                ),
            ).collect { line ->
                // Parse Anthropic SSE: data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
                runCatching {
                    val json = Json.parseToJsonElement(line)
                    if (json is JsonObject) {
                        val type = json["type"]?.toString()?.trim('"')
                        if (type == "content_block_delta") {
                            val delta = json["delta"] as? JsonObject
                            val deltaType = delta?.get("type")?.toString()?.trim('"')
                            if (deltaType == "text_delta") {
                                val text = delta?.get("text")?.toString()?.trim('"')
                                if (!text.isNullOrEmpty()) emit(text)
                            }
                        }
                    }
                }
            }
        }
    }
}
