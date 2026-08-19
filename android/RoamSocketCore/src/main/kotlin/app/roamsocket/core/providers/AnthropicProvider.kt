package app.roamsocket.core.providers

import app.roamsocket.core.protocol.Effort
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
}
