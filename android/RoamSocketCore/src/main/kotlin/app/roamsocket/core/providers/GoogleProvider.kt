package app.roamsocket.core.providers

import app.roamsocket.core.protocol.Effort
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Google Gemini provider: `GET {base}/models`, `POST {base}/models/{model}:generateContent`.
 * Mirrors `ios/AnyProvCore/.../GoogleProvider.swift`.
 */
public class GoogleProvider(
    override val id: ProviderId = ProviderId.Google,
    private val http: HTTPClient = OkHttpHTTPClient(),
    private val baseURL: String = "https://generativelanguage.googleapis.com/v1beta",
) : ModelProvider {

    @Serializable
    private data class ModelList(val models: List<Model> = emptyList()) {
        @Serializable
        data class Model(
            val name: String,
            @SerialName("displayName") val displayName: String? = null,
        )
    }

    override suspend fun listModels(apiKey: String): List<AIModel> {
        if (apiKey.isEmpty()) throw ProviderError.MissingKey
        val response = http.data(
            ProviderHTTP.get(
                url = "$baseURL/models?key=$apiKey",
                headers = emptyMap(),
            ),
        )
        return runCatching {
            val list = Json { ignoreUnknownKeys = true }
                .decodeFromString(ModelList.serializer(), response.body)
            list.models.map { m ->
                // `models/gemini-2.0-flash` → `gemini-2.0-flash`.
                val short = m.name.removePrefix("models/")
                AIModel(
                    provider = id,
                    modelID = short,
                    displayName = m.displayName ?: short,
                )
            }
        }.getOrElse { throw ProviderError.Decoding(it.message ?: it.javaClass.simpleName) }
    }

    @Serializable
    private data class GenerateRequest(val contents: List<Content>) {
        @Serializable
        data class Content(val role: String? = null, val parts: List<Part>) {
            @Serializable
            data class Part(
                val text: String? = null,
                @SerialName("inline_data") val inlineData: InlineData? = null,
            ) {
                @Serializable
                data class InlineData(
                    @SerialName("mime_type") val mimeType: String,
                    val data: String,
                )
            }
        }
    }

    @Serializable
    private data class GenerateResponse(val candidates: List<Candidate> = emptyList()) {
        @Serializable
        data class Candidate(val content: Content? = null) {
            @Serializable
            data class Content(val parts: List<Part> = emptyList()) {
                @Serializable
                data class Part(val text: String? = null)
            }
        }
    }

    override suspend fun chat(
        model: String,
        apiKey: String,
        messages: List<ProviderChatMessage>,
        effort: Effort?,
    ): String {
        if (apiKey.isEmpty()) throw ProviderError.MissingKey
        val contents = messages
            .filter { it.role != ProviderChatMessage.Role.SYSTEM }
            .map { m ->
                GenerateRequest.Content(
                    role = if (m.role == ProviderChatMessage.Role.USER) "user" else "model",
                    parts = buildList {
                        for (image in m.images) {
                            add(
                                GenerateRequest.Content.Part(
                                    inlineData = GenerateRequest.Content.Part.InlineData(
                                        mimeType = image.mimeType,
                                        data = image.base64Data,
                                    ),
                                ),
                            )
                        }
                        val text = m.content.trim()
                        if (text.isNotEmpty()) add(GenerateRequest.Content.Part(text = text))
                    },
                )
            }
        val system = messages.filter { it.role == ProviderChatMessage.Role.SYSTEM }
            .joinToString("\n\n") { it.content }
            .takeIf { it.isNotEmpty() }

        val body = buildJsonObject {
            put("contents", Json.encodeToJsonElement(GenerateRequest.serializer(), GenerateRequest(contents)))
            if (system != null) {
                put("systemInstruction", buildJsonObject {
                    put("parts", buildJsonArray { add(buildJsonObject { put("text", system) }) })
                })
            }
        }

        val response = http.data(
            ProviderHTTP.post(
                url = "$baseURL/models/$model:generateContent?key=$apiKey",
                headers = mapOf("content-type" to "application/json"),
                body = body.toString(),
            ),
        )
        return runCatching {
            val parsed = Json { ignoreUnknownKeys = true }
                .decodeFromString(GenerateResponse.serializer(), response.body)
            parsed.candidates.firstOrNull()?.content?.parts?.mapNotNull { it.text }?.joinToString("\n").orEmpty()
        }.getOrElse { throw ProviderError.Decoding(it.message ?: it.javaClass.simpleName) }
    }
}
