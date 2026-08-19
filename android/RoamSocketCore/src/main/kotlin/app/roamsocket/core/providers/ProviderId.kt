/*
 * Provider identifiers — mirror of `ios/AnyProvCore/.../Providers/AIModel.swift`'s
 * `ProviderID` enum. Built-in providers are fixed cases; user-defined
 * endpoints use `custom(slug)` and serialise as `"custom:<slug>"` so they
 * never collide with first-party ids.
 */
package app.roamsocket.core.providers

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

@Serializable(with = ProviderId.Serializer::class)
public sealed class ProviderId {

    public abstract val rawValue: String
    public open val displayName: String get() = rawValue
    public open val requiresApiKey: Boolean get() = true
    public open val supportsCodingAgent: Boolean get() = true
    public open val customSlug: String? get() = null

    public object Anthropic : ProviderId() {
        override val rawValue: String = "anthropic"
        override val displayName: String = "Anthropic"
    }

    public object OpenAI : ProviderId() {
        override val rawValue: String = "openai"
        override val displayName: String = "OpenAI"
    }

    public object Google : ProviderId() {
        override val rawValue: String = "google"
        override val displayName: String = "Google Gemini"
        override val supportsCodingAgent: Boolean = false
    }

    public object Groq : ProviderId() {
        override val rawValue: String = "groq"
        override val displayName: String = "Groq"
    }

    public object OpenRouter : ProviderId() {
        override val rawValue: String = "openrouter"
        override val displayName: String = "OpenRouter"
    }

    public object XAI : ProviderId() {
        override val rawValue: String = "xai"
        override val displayName: String = "xAI"
    }

    public object Mistral : ProviderId() {
        override val rawValue: String = "mistral"
        override val displayName: String = "Mistral"
    }

    public object MiniMax : ProviderId() {
        override val rawValue: String = "minimax"
        override val displayName: String = "MiniMax"
    }

    /** On-device Metal/MLX model. iOS-only; Android has no equivalent today. */
    public object LocalMetal : ProviderId() {
        override val rawValue: String = "local-metal"
        override val displayName: String = "On-device (Metal)"
        override val requiresApiKey: Boolean = false
    }

    public data class Custom(public val slug: String) : ProviderId() {
        override val rawValue: String = "custom:" + slug
        override val displayName: String = slug
        override val customSlug: String = slug
    }

    /** Built-in providers, in stable display order. */
    public companion object {
        public val BUILT_IN: List<ProviderId> by lazy {
            listOf(
                Anthropic, OpenAI, Google, Groq, OpenRouter, XAI, Mistral, MiniMax, LocalMetal,
            )
        }

        public fun fromRawValue(raw: String): ProviderId? {
            return when (raw) {
                "anthropic" -> Anthropic
                "openai" -> OpenAI
                "google" -> Google
                "groq" -> Groq
                "openrouter" -> OpenRouter
                "xai" -> XAI
                "mistral" -> Mistral
                "minimax", "mini-max" -> MiniMax
                "local-metal", "localMetal", "local", "metal" -> LocalMetal
                else -> if (raw.startsWith("custom:")) {
                    val slug = raw.removePrefix("custom:")
                    if (slug.isNotEmpty()) Custom(slug) else null
                } else {
                    null
                }
            }
        }
    }

    internal object Serializer : KSerializer<ProviderId> {
        override val descriptor: SerialDescriptor =
            PrimitiveSerialDescriptor("app.roamsocket.core.providers.ProviderId", PrimitiveKind.STRING)

        override fun serialize(encoder: Encoder, value: ProviderId) {
            encoder.encodeString(value.rawValue)
        }

        override fun deserialize(decoder: Decoder): ProviderId {
            val raw = decoder.decodeString()
            return fromRawValue(raw)
                ?: throw IllegalArgumentException("Unknown provider id: " + raw)
        }
    }
}
