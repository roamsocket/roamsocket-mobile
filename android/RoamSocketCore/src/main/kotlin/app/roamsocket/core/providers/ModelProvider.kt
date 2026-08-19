package app.roamsocket.core.providers

import app.roamsocket.core.protocol.Effort
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Errors surfaced by provider clients. */
public sealed class ProviderError(message: String) : RuntimeException(message) {
    public object MissingKey : ProviderError("No API key configured for this provider.")
    public data class Http(val status: Int, val body: String) :
        ProviderError("HTTP $status: ${readableMessage(body) ?: body}")

    public data class Decoding(val detail: String) :
        ProviderError("Failed to decode response: $detail")

    public data class Transport(val detail: String) : ProviderError("Network error: $detail")

    public companion object {
        /**
         * Pull a human-readable message out of a provider error body. Most
         * APIs return `{"error":{"message":"…"}}` or `{"error":"…"}` on
         * failure. Returns null for non-JSON bodies.
         */
        public fun readableMessage(body: String): String? {
            return runCatching {
                val obj = Json.parseToJsonElement(body).let { it as? kotlinx.serialization.json.JsonObject } ?: return@runCatching null
                val err = obj["error"]
                when (err) {
                    is kotlinx.serialization.json.JsonObject -> err["message"]?.toString()?.trim('"')
                    is kotlinx.serialization.json.JsonPrimitive -> if (err.isString) err.content else null
                    else -> null
                }
            }.getOrNull()
        }
    }
}

/** HTTP client surface a provider needs. Injected for testing. */
public interface HTTPClient {
    public suspend fun data(request: Request): HTTPResponse
}

public data class HTTPResponse(
    val status: Int,
    val body: String,
    val headers: Headers,
)

/** OkHttp-backed default [HTTPClient]. */
public class OkHttpHTTPClient(
    private val client: OkHttpClient = defaultClient(),
) : HTTPClient {
    override suspend fun data(request: Request): HTTPResponse = withContext(Dispatchers.IO) {
        try {
            client.newCall(request).execute().use(::toResponse)
        } catch (e: ProviderError) {
            throw e
        } catch (e: IOException) {
            throw ProviderError.Transport(e.message ?: e.javaClass.simpleName)
        } catch (e: Exception) {
            throw ProviderError.Transport(e.message ?: e.javaClass.simpleName)
        }
    }

    private fun toResponse(response: Response): HTTPResponse {
        val body = response.body?.string().orEmpty()
        if (!response.isSuccessful) {
            throw ProviderError.Http(response.code, body)
        }
        return HTTPResponse(response.code, body, response.headers)
    }

    public companion object {
        public fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS)
            .callTimeout(180, TimeUnit.SECONDS)
            .build()
    }
}

/**
 * A provider client that can list models and run chat completions. Mirrors
 * the iOS `ModelProvider` protocol. Streaming is added in a later PR.
 */
public interface ModelProvider {
    public val id: ProviderId

    /** Fetch the models this key can access. */
    public suspend fun listModels(apiKey: String): List<AIModel>

    /** Run a single chat completion and return the assistant's reply text. */
    public suspend fun chat(
        model: String,
        apiKey: String,
        messages: List<ProviderChatMessage>,
        effort: Effort?,
    ): String

    /** Run a chat completion with an optional native web-search query. */
    public suspend fun chat(
        model: String,
        apiKey: String,
        messages: List<ProviderChatMessage>,
        effort: Effort?,
        webSearchQuery: String?,
    ): String = chat(model, apiKey, messages, effort)
}

/** A single message in a chat turn, scoped to provider APIs. */
@Serializable
public data class ProviderChatMessage(
    val role: Role,
    val content: String,
    /** Inline image for multimodal chat. Empty for text-only turns. */
    val images: List<ImageAttachment> = emptyList(),
) {
    public val hasImages: Boolean get() = images.isNotEmpty()

    @Serializable
    public enum class Role {
        @kotlinx.serialization.SerialName("system") SYSTEM,
        @kotlinx.serialization.SerialName("user") USER,
        @kotlinx.serialization.SerialName("assistant") ASSISTANT,
        ;
    }

    @Serializable
    public data class ImageAttachment(
        /** MIME type, e.g. `image/jpeg` or `image/png`. */
        val mimeType: String,
        /** Raw base64 (no data-URL prefix). */
        val base64Data: String,
    ) {
        /** `data:{mime};base64,{data}` for OpenAI-compatible `image_url` payloads. */
        public val dataURL: String get() = "data:$mimeType;base64,$base64Data"
    }
}

/** Shared helpers for building requests. */
internal object ProviderHTTP {
    private val JSON = "application/json".toMediaType()

    fun get(url: String, headers: Map<String, String>): Request =
        Request.Builder().url(url).headers(headers.toHeaders()).get().build()

    fun post(url: String, headers: Map<String, String>, body: String): Request =
        Request.Builder()
            .url(url)
            .headers(headers.toHeaders())
            .post(body.toRequestBody(JSON))
            .build()

    private fun Map<String, String>.toHeaders(): Headers {
        val b = Headers.Builder()
        for ((k, v) in this) b.add(k, v)
        return b.build()
    }
}
