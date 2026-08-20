/*
 * Wire protocol — Kotlin mirror of `desktop-server/src/protocol.ts` and
 * `ios/AnyProvCore/Sources/AnyProvCore/Server/Protocol.swift`.
 *
 * Pairing happens over HTTP (POST /pair → bearer token). The app then opens
 * a WebSocket to `/session?token=…`. Every frame is a JSON object validated
 * by the schema on the server; kotlinx.serialization decodes/encodes here.
 *
 * When changing this file, update all three: TS, Swift, Kotlin, plus
 * `docs/protocol.md` per the repo's protocol-triple invariant.
 */
package app.roamsocket.core.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonClassDiscriminator

/** Provider identifiers understood by both the app and the server. */
public val BUILT_IN_PROVIDER_IDS: Set<String> = setOf(
    "anthropic",
    "openai",
    "google",
    "groq",
    "openrouter",
    "xai",
    "mistral",
    "minimax",
    "localMetal",
)

/** HTTP shape for chat/completions vs Anthropic messages. */
@Serializable
public enum class ApiStyle {
    @SerialName("openai") OPENAI,
    @SerialName("anthropic") ANTHROPIC,
}

/** Reasoning effort; maps to provider-specific knobs where supported. */
@Serializable
public enum class Effort {
    @SerialName("low") LOW,
    @SerialName("medium") MEDIUM,
    @SerialName("high") HIGH,
}

/** Permission mode, mirroring the composer's permission pill. */
@Serializable
public enum class PermissionMode {
    @SerialName("acceptEdits") ACCEPT_EDITS,
    @SerialName("plan") PLAN,
    @SerialName("ask") ASK;

    public val displayName: String
        get() = when (this) {
            ACCEPT_EDITS -> "Accept edits"
            PLAN -> "Plan"
            ASK -> "Ask"
        }
}

/** Network access policy for a cloud environment. */
@Serializable
public enum class NetworkAccess {
    @SerialName("trusted") TRUSTED,
    @SerialName("limited") LIMITED,
    @SerialName("none") NONE,
    @SerialName("custom") CUSTOM;

    public val displayName: String
        get() = when (this) {
            TRUSTED -> "Trusted network access"
            LIMITED -> "Limited network access"
            NONE -> "No network access"
            CUSTOM -> "Custom"
        }

    public val subtitle: String
        get() = when (this) {
            TRUSTED -> "Downloads packages from verified sources."
            LIMITED -> "Unrestricted internet access for maximum flexibility."
            NONE -> "Blocks internet access for maximum security."
            CUSTOM -> "Create a list of allowed domains."
        }
}

/**
 * A cloud-environment configuration created in the app (matches the iOS
 * `.env` editor). `variables` is parsed from `.env`-format text.
 */
@Serializable
public data class EnvironmentConfig(
    val name: String,
    val networkAccess: NetworkAccess = NetworkAccess.TRUSTED,
    val allowedDomains: List<String> = emptyList(),
    val variables: Map<String, String> = emptyMap(),
) {
    public companion object {
        /** Parse `.env`-format text into KEY=value variables. */
        public fun parseEnv(text: String): Map<String, String> {
            val out = mutableMapOf<String, String>()
            for (rawLine in text.lineSequence().map { it.trim() }) {
                if (rawLine.isEmpty() || rawLine.startsWith("#")) continue
                val eq = rawLine.indexOf('=')
                if (eq < 0) continue
                val key = rawLine.substring(0, eq).trim()
                var value = rawLine.substring(eq + 1).trim()
                if (value.length >= 2 &&
                    ((value.startsWith("\"") && value.endsWith("\"")) ||
                        (value.startsWith("'") && value.endsWith("'")))
                ) {
                    value = value.substring(1, value.length - 1)
                }
                if (key.isNotEmpty()) out[key] = value
            }
            return out
        }
    }
}

/** A skill that provides guidance to the agent. */
@Serializable
public data class Skill(
    val id: String,
    val name: String,
    val description: String,
    val content: String,
    val category: String,
    val source: SkillSource,
    val isEnabled: Boolean,
    val frontmatter: Map<String, String> = emptyMap(),
)

@Serializable
public enum class SkillSource {
    @SerialName("official") OFFICIAL,
    @SerialName("community") COMMUNITY,
    @SerialName("custom") CUSTOM,
}

/** An MCP server configuration. */
@Serializable
public data class MCPServer(
    val id: String,
    val name: String,
    val description: String,
    val command: String,
    val args: List<String> = emptyList(),
    val env: Map<String, String> = emptyMap(),
    val isEnabled: Boolean,
)

/** A single user-memory entry. */
@Serializable
public data class MemoryEntryPayload(
    val id: String,
    val category: MemoryCategory,
    val title: String,
    val summary: String = "",
    val details: List<String> = emptyList(),
    val updatedAt: Long,
)

@Serializable
public enum class MemoryCategory {
    @SerialName("you") YOU,
    @SerialName("topic") TOPIC,
    @SerialName("area") AREA,
}

/** The model + provider the agent should run with. */
@Serializable
public data class ModelSelection(
    val provider: String,
    val model: String,
    val effort: Effort = Effort.HIGH,
    val apiKey: String,
    /** Optional override for custom / proxy endpoints (e.g. `http://host/v1`). */
    val baseUrl: String? = null,
    val apiStyle: ApiStyle? = null,
)
