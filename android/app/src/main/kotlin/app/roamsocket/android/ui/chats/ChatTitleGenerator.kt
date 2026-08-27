package app.roamsocket.android.ui.chats

import app.roamsocket.android.AppContainer
import app.roamsocket.android.ui.lightweight.LightweightTaskRunner
import app.roamsocket.core.chats.PersistedChatMessage

/**
 * Suggests a short display title for a chat. Mirrors the iOS
 * `Chats/ChatTitleGenerator.swift` surface:
 *
 * 1. If the user has a linked lightweight model, ask it for a
 *    short title (1-6 words) and sanitize the result.
 * 2. Otherwise, fall back to the heuristic "first 6 words of the
 *    first user message".
 *
 * Never overwrites a user-edited title; the caller is responsible
 * for that check.
 */
object ChatTitleGenerator {

    const val MAX_TITLE_LENGTH: Int = 48

    private const val SYSTEM_PROMPT =
        "You title chat conversations. Reply with a short, descriptive " +
            "title of 1-6 words. No quotes, no trailing punctuation, no " +
            "explanation. Output only the title."

    /**
     * Suggest a title for the chat whose first user message is
     * `messages.firstOrNull { role == USER }`. Returns
     * `currentTitle` unchanged when the chat has no user message
     * yet.
     */
    suspend fun suggestTitle(
        container: AppContainer,
        messages: List<PersistedChatMessage>,
        currentTitle: String,
    ): String {
        val firstUser = messages.firstOrNull { it.role == PersistedChatMessage.Role.USER }
            ?: return currentTitle
        val firstText = firstUser.content.trim()
        if (firstText.isEmpty()) return currentTitle

        val lightweight = LightweightTaskRunner.complete(
            container = container,
            system = SYSTEM_PROMPT,
            user = firstText,
            maxTokens = 16,
        )
        if (!lightweight.isNullOrBlank()) {
            return sanitize(lightweight)
        }
        return heuristic(firstText)
    }

    /** First 6 words of [text], capped at [MAX_TITLE_LENGTH]. */
    fun heuristic(text: String): String {
        val cleaned = text.trim().replace(Regex("\\s+"), " ")
        if (cleaned.isEmpty()) return ""
        val words = cleaned.split(' ').take(6).joinToString(" ")
        return if (words.length <= MAX_TITLE_LENGTH) {
            words
        } else {
            // Reserve one slot for the ellipsis so the final string
            // never exceeds [MAX_TITLE_LENGTH] (matches iOS
            // `prefix(maxTitleLength - 1) + "…"`).
            words.substring(0, MAX_TITLE_LENGTH - 1).trimEnd { it == ' ' || it == ',' } + "\u2026"
        }
    }

    /**
     * Strip common wrappers and prefixes an LLM might add (quotes,
     * leading "Title:", trailing period) and cap at
     * [MAX_TITLE_LENGTH].
     */
    fun sanitize(raw: String): String {
        var text = raw.trim()
        if (text.isEmpty()) return ""

        val newline = text.indexOf('\n')
        if (newline >= 0) text = text.substring(0, newline).trim()

        val wrappers = charArrayOf('"', '\'', '`', '*', '\u201C', '\u201D', '\u2018', '\u2019')
        while (
            text.length > 2 &&
            wrappers.contains(text.first()) &&
            wrappers.contains(text.last())
        ) {
            text = text.substring(1, text.length - 1).trim()
        }

        for (prefix in listOf("Title:", "Name:", "Chat:")) {
            if (text.startsWith(prefix, ignoreCase = true)) {
                text = text.substring(prefix.length).trim()
            }
        }

        if (text.endsWith('.') && text.length <= 36 && !text.dropLast(1).contains('.')) {
            text = text.dropLast(1)
        }

        if (text.isEmpty()) return ""
        if (text.length <= MAX_TITLE_LENGTH) return text
        return text.take(MAX_TITLE_LENGTH - 1) + "\u2026"
    }
}
