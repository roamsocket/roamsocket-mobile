package app.roamsocket.core.projects

/**
 * Pure function for applying natural-language commands to a project's
 * private memory. Mirrors the iOS
 * `ChatHistoryStore.applyProjectMemoryCommand` heuristic:
 *
 * - `"forget <topic>"`     → strip lines containing the topic
 *                            (case-insensitive). If nothing matched,
 *                            append a "user asked to forget" note.
 * - `"remember I <fact>"`,
 *   `"remember that <fact>"`,
 *   `"remember <fact>"`    → append a "• Fact." bullet.
 * - anything else          → append as a freeform bullet.
 *
 * Each new bullet is prefixed with `• ` and joined to the existing
 * memory with `\n\n`. Empty commands return the memory unchanged.
 */
object MemoryCommandParser {

    private val REMEMBER_THAT_REGEX = Regex(
        """^remember that(?: i)?\s+""",
        option = RegexOption.IGNORE_CASE,
    )

    fun apply(currentMemory: String, command: String): String {
        val cmd = command.trim()
        if (cmd.isEmpty()) return currentMemory
        val lower = cmd.lowercase()

        if (lower.startsWith("forget ")) {
            val topic = cmd.drop(7).trim()
                .trim { it == '*' || it == '"' || it == '\'' }
            if (topic.isEmpty()) return currentMemory
            val filtered = currentMemory
                .lines()
                .filter { !it.contains(topic, ignoreCase = true) }
            val joined = filtered.joinToString("\n").trim()
            val trimmed = currentMemory.trim()
            return if (joined == trimmed) {
                if (currentMemory.isEmpty()) {
                    "Note: user asked to forget \u201C$topic\u201D."
                } else {
                    "$currentMemory\n\nNote: user asked to forget \u201C$topic\u201D."
                }
            } else {
                joined
            }
        }

        if (lower.startsWith("remember that")) {
            val fact = REMEMBER_THAT_REGEX.replace(cmd, "").trim()
            if (fact.isEmpty()) return currentMemory
            val bullet = "\u2022 " + fact.first().uppercaseChar() + fact.drop(1)
            return appendBullet(currentMemory, bullet)
        }

        if (lower.startsWith("remember ")) {
            val fact = cmd.drop(9).trim()
            if (fact.isEmpty()) return currentMemory
            val bullet = "\u2022 " + fact.first().uppercaseChar() + fact.drop(1)
            return appendBullet(currentMemory, bullet)
        }

        // Freeform.
        val bullet = "\u2022 $cmd"
        return appendBullet(currentMemory, bullet)
    }

    private fun appendBullet(currentMemory: String, bullet: String): String =
        if (currentMemory.isEmpty()) bullet else "$currentMemory\n\n$bullet"
}
