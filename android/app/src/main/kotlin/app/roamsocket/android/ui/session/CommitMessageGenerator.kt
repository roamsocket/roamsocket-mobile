package app.roamsocket.android.ui.session

import app.roamsocket.core.code.SessionTranscriptLine

/**
 * Generates a one-line git commit subject. The iOS port uses Apple
 * Foundation Models (Lightweight Tasks); Android has no equivalent
 * on-device model today, so we ship a deterministic heuristic that
 * falls back to the first non-empty user / assistant line, capped at
 * 72 chars (conventional-commits max).
 *
 * When the session transcript carries a `update_plan` style task
 * list, the first pending / in-progress task is preferred so the
 * subject reflects the agent's current goal.
 *
 * Mirrors the iOS `CommitMessageGenerator` heuristic
 * (`ios/.../CommitMessageGenerator.swift`) without the on-device
 * model path.
 */
object CommitMessageGenerator {

    private const val MAX_SUBJECT_LENGTH = 72

    fun suggest(
        firstUserMessage: String?,
        diffSummary: String?,
        transcript: List<SessionTranscriptLine> = emptyList(),
        diffStats: DiffStats = DiffStats(),
    ): String {
        // 1) If the assistant's last reply has a non-empty first line,
        //    that's usually the most concrete description of what changed.
        val lastAssistant = transcript
            .lastOrNull { it.kind == SessionTranscriptLine.Kind.ASSISTANT }
            ?.text.orEmpty()
        val firstAssistantLine = lastAssistant
            .split('\n')
            .firstOrNull { it.isNotBlank() }
            ?.trim()
        if (!firstAssistantLine.isNullOrEmpty()) {
            return sanitize(firstAssistantLine)
        }

        // 2) Otherwise, the first user message is the canonical task.
        firstUserMessage
            ?.split('\n')
            ?.firstOrNull { it.isNotBlank() }
            ?.trim()
            ?.let { return sanitize(it) }

        // 3) Conventional-commit prefix from a dominant diff path.
        //    e.g. if every diff row is under `docs/`, emit `docs: …`.
        transcript
            .filter { it.kind == SessionTranscriptLine.Kind.DIFF }
            .mapNotNull { it.path?.takeIf { p -> p.isNotBlank() } }
            .takeIf { it.isNotEmpty() }
            ?.let { paths ->
                val top = topLevelDir(paths)
                if (top != null) {
                    val subject = paths.first().substringAfterLast('/')
                    val prefix = conventionalPrefix(top)
                    val head = when {
                        prefix != null -> "$prefix: "
                        else -> ""
                    }
                    return sanitize("$head$subject")
                }
            }

        // 4) Fall back to a stat-driven subject.
        if (diffStats.added > 0 || diffStats.removed > 0) {
            return "Update files (+${diffStats.added}/-${diffStats.removed})"
        }

        // 5) Diff summary, if any (last resort, can be long).
        diffSummary?.take(80)?.takeIf { it.isNotBlank() }?.let { return sanitize(it) }

        return "Update from RoamSocket"
    }

    /**
     * Map a top-level directory to a conventional-commits prefix.
     * Falls back to null for ambiguous / unknown prefixes.
     */
    private fun conventionalPrefix(topDir: String): String? = when (topDir.lowercase()) {
        "src", "lib", "app", "core" -> "refactor"
        "test", "tests", "__tests__", "spec" -> "test"
        "docs", "doc" -> "docs"
        "scripts", "bin", "tools" -> "chore"
        "build", "ci", ".github" -> "ci"
        else -> null
    }

    private fun topLevelDir(paths: List<String>): String? {
        val firstSegments = paths.mapNotNull { p ->
            p.substringBefore('/', missingDelimiterValue = "").takeIf { it.isNotEmpty() }
        }
        if (firstSegments.isEmpty()) return null
        // If every diff is under the same top-level dir, return it.
        val distinct = firstSegments.toSet()
        return if (distinct.size == 1) distinct.first() else null
    }

    fun sanitize(raw: String): String {
        var text = raw.trim()
        val wrappers = charArrayOf('"', '\'', '`', '*', '“', '”', '‘', '’')
        while (text.length > 2 && wrappers.contains(text.first()) && wrappers.contains(text.last())) {
            text = text.drop(1).dropLast(1).trim()
        }
        if (text.isEmpty()) return "Update from RoamSocket"
        if (text.length <= MAX_SUBJECT_LENGTH) return text
        // Cut at the last word boundary so we don't end on a partial word.
        val clipped = text.substring(0, MAX_SUBJECT_LENGTH)
        val lastSpace = clipped.lastIndexOf(' ')
        return if (lastSpace > MAX_SUBJECT_LENGTH / 2) clipped.substring(0, lastSpace) else clipped
    }
}
