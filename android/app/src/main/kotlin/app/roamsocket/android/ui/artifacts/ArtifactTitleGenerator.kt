package app.roamsocket.android.ui.artifacts

/**
 * Generates a short display title for an artifact.
 *
 * iOS prefers **Lightweight Tasks** (Apple Foundation Model or a
 * user-linked model) and falls back to a heuristic. Android currently
 * has no on-device model, so we always use the heuristic — the public
 * surface mirrors the iOS API so the call site in `ChatViewModel`
 * stays the same and we can plug in a real backend later
 * (the LightweightTasks port will provide one).
 *
 * Ports `ArtifactTitleGenerator` from
 * `ios/App/Sources/Features/Artifacts/ArtifactTitleGenerator.swift`.
 */
object ArtifactTitleGenerator {
    const val MAX_TITLE_LENGTH: Int = 64

    /**
     * Suggest a title. Currently always returns the heuristic. When
     * Android gets an on-device model (LightweightTasks port), this
     * will try that first and fall back to the heuristic.
     */
    suspend fun suggestTitle(content: String): String = heuristicTitle(content)

    /**
     * First useful line: prefer the language tag from a code fence, or
     * a heading, or the first non-empty, non-fence line.
     */
    fun heuristicTitle(content: String): String {
        val fenceMatch = Regex("""```(\w+)?""").find(content)
        if (fenceMatch != null) {
            val fenceStart = fenceMatch.range.first
            val lineStart = content.lastIndexOf('\n', startIndex = fenceStart).let { it + 1 }
            val lineEnd = content.indexOf('\n', startIndex = fenceStart).let { if (it < 0) content.length else it }
            val fenceLine = content.substring(lineStart, lineEnd).trim()
            if (fenceLine.startsWith("```")) {
                val lang = fenceLine.removePrefix("```").trim()
                val after = content.substring(lineEnd + 1)
                for (raw in after.split('\n').take(3)) {
                    val line = raw.trim()
                    if (line.isEmpty()) continue
                    if (line.startsWith("```")) break
                    val snippet = line.take(40)
                    return sanitize(if (lang.isEmpty()) snippet else "$lang: $snippet")
                }
                if (lang.isNotEmpty()) return sanitize("$lang code")
            }
        }

        for (raw in content.split('\n')) {
            var line = raw.trim()
            if (line.startsWith("```")) continue
            if (line.startsWith("#")) {
                line = line.dropWhile { it == '#' }.trim()
            }
            if (line.isNotEmpty()) {
                return sanitize(line.take(MAX_TITLE_LENGTH))
            }
        }
        return "Artifact"
    }

    /**
     * Strip common wrappers and prefixes an LLM might add
     * (quotes, leading "Title:", trailing period, …).
     */
    fun sanitize(raw: String): String {
        var text = raw.trim()
        if (text.isEmpty()) return "Artifact"

        // Drop everything after the first newline (model only returns the title).
        val newline = text.indexOf('\n')
        if (newline >= 0) {
            text = text.substring(0, newline).trim()
        }

        // Strip matched quote-style wrappers ("…", '…", `…`).
        val wrappers = charArrayOf('"', '\'', '`', '*', '“', '”', '‘', '’')
        while (
            text.length > 2 &&
            wrappers.contains(text.first()) &&
            wrappers.contains(text.last())
        ) {
            text = text.substring(1, text.length - 1).trim()
        }

        // Strip leading "Title:" / "Name:" / "Artifact:".
        for (prefix in listOf("Title:", "Name:", "Artifact:")) {
            if (text.startsWith(prefix, ignoreCase = true)) {
                text = text.substring(prefix.length).trim()
            }
        }

        // Drop a single trailing period on short titles.
        if (text.endsWith('.') && text.length <= 48 && !text.dropLast(1).contains('.')) {
            text = text.dropLast(1)
        }

        if (text.isEmpty()) return "Artifact"
        if (text.length <= MAX_TITLE_LENGTH) return text
        return text.take(MAX_TITLE_LENGTH - 1) + "…"
    }
}
