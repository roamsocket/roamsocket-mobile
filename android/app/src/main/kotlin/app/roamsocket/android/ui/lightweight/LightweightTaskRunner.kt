package app.roamsocket.android.ui.lightweight

import app.roamsocket.android.AppContainer
import app.roamsocket.core.providers.ProviderChatMessage
import app.roamsocket.core.protocol.Effort
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Runs short helper completions (chat titles, artifact names, commit
 * subjects, thinking summaries) through a user-linked BYOK model.
 *
 * iOS additionally has an Apple Intelligence (on-device Foundation
 * Model) backend. Android has no Foundation-Model equivalent today,
 * so we only ship the linked-model path. The iOS
 * `LightweightTaskRunner.complete(...)` signature is kept verbatim so
 * adding an on-device backend later is a one-file change.
 *
 * Mirrors `ios/.../Features/LightweightTasks/LightweightTaskRunner.swift`.
 */
object LightweightTaskRunner {

    /**
     * Run a short completion. Returns the trimmed reply, or `null` if
     * the linked model isn't configured, has no API key, or the call
     * fails for any reason. Callers should always have a heuristic
     * fallback ready (the title generators all do).
     */
    suspend fun complete(
        container: AppContainer,
        system: String,
        user: String,
        maxTokens: Int = 48,
    ): String? {
        val settings = container.lightweightTasksStore.settings.value
        if (!settings.hasLinkedModel) return null
        val provider = settings.linkedProvider ?: return null
        val modelID = settings.linkedModelID ?: return null

        val apiKey = container.secretStore.readApiKey(provider)
        val key = when {
            !apiKey.isNullOrEmpty() -> apiKey
            !provider.requiresApiKey -> "local"
            else -> return null
        }
        if (key.isEmpty()) return null

        val client = container.chatClientFor(provider) ?: return null

        val messages = buildList {
            if (system.isNotBlank()) {
                add(ProviderChatMessage(role = ProviderChatMessage.Role.SYSTEM, content = system))
            }
            add(ProviderChatMessage(role = ProviderChatMessage.Role.USER, content = user))
        }

        return runCatching {
            withContext(Dispatchers.IO) {
                client.chat(
                    model = modelID,
                    apiKey = key,
                    messages = messages,
                    effort = Effort.LOW,
                )
            }
        }.getOrNull()?.trim()?.takeIf { it.isNotEmpty() }
    }
}
