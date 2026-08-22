package app.roamsocket.android.ui.chat

/**
 * Pure-Kotlin port of the iOS `ThinkingExtractor` (`ios/.../ThinkingExtractor.swift`).
 *
 * Pulls model reasoning out of assistant text that wraps it in
 * `<think>…</think>` (or `<thinking>…</thinking>` etc.) so the UI can show
 * it as a collapsed block instead of raw markup.
 *
 * Also strips leaked provider tool-call XML (`minimax:tool_call`,
 * `function_calls`, bare `<invoke …>` blocks) so raw markup never reaches
 * the chat bubble when the model emits tool calls the Android client
 * doesn't parse on the chat path.
 */
object ThinkingExtractor {

    data class Result(
        /** Inner reasoning text. Non-null when thinking tags were detected
         *  (empty string while streaming an open tag with no body yet). */
        val thinking: String?,
        /** Original string with thinking tags removed (trimmed). */
        val content: String,
    )

    // Tag names treated as reasoning/scratch containers. Matches iOS
    // (think / thinking / reasoning / reflection / thought / analysis /
    // scratch_pad). Inlined into the regexes below — repeating the
    // pattern verbatim means we don't need a backref and open and close
    // always match.
    private const val THINKING_TAGS =
        "think|thinking|reasoning|reflection|thought|analysis|scratch_pad"

    /**
     * Every non-empty prefix of one of the [THINKING_TAGS] names. The
     * incomplete-open-tag pattern matches any word starting with `<`
     * at the end of the stream and we then verify the captured text is
     * actually a known prefix — this lets us catch a streaming
     * `<thin` (a partial `<think>`) without also matching a stray
     * `<span` mid-text.
     */
    private val THINKING_TAG_PREFIXES: Set<String> = run {
        val names = THINKING_TAGS.split('|')
        val out = mutableSetOf<String>()
        for (name in names) {
            for (i in 1..name.length) {
                out.add(name.substring(0, i))
            }
        }
        out
    }

    // Paired <tag>…</tag> blocks (case-insensitive, multi-line).
    private val pairedPattern: Regex =
        Regex("""<($THINKING_TAGS)\b[^>]*>[\s\S]*?</\1>""", RegexOption.IGNORE_CASE)

    // Unclosed <tag>…$ — captures everything after the open tag.
    private val openOnlyPattern: Regex =
        Regex("""<($THINKING_TAGS)\b[^>]*>[\s\S]*$""", RegexOption.IGNORE_CASE)

    // Partial open tag at the end of the stream (`<thi`, `<think`, …).
    // Captures any word-ish prefix; we verify against
    // [THINKING_TAG_PREFIXES] before treating the input as thinking.
    private val incompleteOpenPattern: Regex =
        Regex("""<([A-Za-z][A-Za-z_]*)$""")

    // Stray orphan open/close tags left after primary extraction.
    private val residualTagPattern: Regex =
        Regex("""</?($THINKING_TAGS)\b[^>]*>""", RegexOption.IGNORE_CASE)

    // Anthropic-style `antml:thinking` and other namespaced reasoning
    // containers (Claude Opus 5 leak, antml legacy prompt format).
    private val antmlThinkingPattern: Regex =
        Regex(
            """<antml:(?:thinking|reasoning|reflection|thought|analysis)\b[^>]*>[\s\S]*?</antml:(?:thinking|reasoning|reflection|thought|analysis)>""",
            RegexOption.IGNORE_CASE,
        )

    fun extract(raw: String): Result {
        if (raw.isEmpty()) return Result(thinking = null, content = raw)

        var stripped = raw
        var thinkingParts = mutableListOf<String>()
        var sawThinkingTags = false

        // 1) Strip namespaced `antml:thinking` etc. before the generic
        //    pass so the antml pattern doesn't get caught by a backref
        //    mismatch with the local tag list.
        antmlThinkingPattern.findAll(stripped).toList().forEach { match ->
            sawThinkingTags = true
            val inner = match.value
                .substringAfter('>')
                .substringBeforeLast('<')
                .trim()
            if (inner.isNotEmpty()) thinkingParts.add(inner)
        }
        stripped = antmlThinkingPattern.replace(stripped, "")

        // 2) Paired think/thinking/etc. blocks.
        pairedPattern.findAll(stripped).toList().forEach { match ->
            sawThinkingTags = true
            val inner = match.value
                .substringAfter('>')
                .substringBeforeLast('<')
                .trim()
            if (inner.isNotEmpty()) thinkingParts.add(inner)
        }
        stripped = pairedPattern.replace(stripped, "")

        // 3) Unclosed open tag (still streaming). Keep what we have so
        //    far; drop the rest so the chat bubble doesn't show a torn tag.
        val openMatch = openOnlyPattern.find(stripped)
        if (openMatch != null) {
            sawThinkingTags = true
            val inner = openMatch.value.substringAfter('>').trim()
            if (inner.isNotEmpty()) thinkingParts.add(inner)
            stripped = stripped.substring(0, openMatch.range.first)
        } else {
            // 4) Partial open tag at the end of the stream (`<thi`,
            //    `<think`, …). We match any word-like prefix and then
            //    verify it's a known thinking-tag prefix so a stray
            //    `<span` mid-text isn't treated as a thinking tag.
            val incomplete = incompleteOpenPattern.find(stripped)
            if (incomplete != null &&
                THINKING_TAG_PREFIXES.contains(incomplete.groupValues[1].lowercase())
            ) {
                sawThinkingTags = true
                stripped = stripped.substring(0, incomplete.range.first)
            }
        }

        // 5) Orphan close/open tags left behind.
        if (residualTagPattern.containsMatchIn(stripped)) {
            sawThinkingTags = true
            stripped = residualTagPattern.replace(stripped, "")
        }

        val thinking = if (sawThinkingTags) thinkingParts.joinToString("\n\n") else null
        return Result(thinking = thinking, content = tidy(stripped))
    }

    /** Visible answer only — thinking markup removed. Use for commit
     *  subjects, titles, and any plain-text sink that must not see
     *  `<think>` tokens. */
    fun plainVisibleText(raw: String): String = extract(raw).content

    // MARK: - Provider control-token strip

    // Llama 3 / Qwen / Phi / Gemma tokenizer special tokens.
    private val controlTokenPattern: Regex =
        Regex(
            """<\|\s*(?:begin_of_text|end_of_text|start_header_id|end_header_id|eot_id|eom_id|python_tag|user|assistant|system|end|endoftext|im_start|im_end)\s*\|>""",
            RegexOption.IGNORE_CASE,
        )

    // Gemma-family plain-text turn markers.
    private val gemmaTurnPattern: Regex =
        Regex(
            """</?start_of_turn\b[^>]*>|</?end_of_turn\b[^>]*>|<\|turn\|>|<turn\|>""",
            RegexOption.IGNORE_CASE,
        )

    // Mistral [INST]…[/INST] orphan brackets.
    private val mistralInstPattern: Regex = Regex("""\[/?INST]""")

    // Mistral [TOOL_CALLS][ opener.
    private val mistralToolCallsOpener: Regex = Regex("""\[TOOL_CALLS]\[""")

    // Gemini `unusedNN>` placeholders.
    private val geminiUnusedPattern: Regex =
        Regex("""<unused\d+\b[^>]*>""", RegexOption.IGNORE_CASE)

    /** Strip leaked tokenizer / turn-marker control tokens. */
    fun stripControlTokens(raw: String): String {
        if (raw.isEmpty()) return raw
        var s = raw
        s = controlTokenPattern.replace(s, "")
        s = gemmaTurnPattern.replace(s, "")
        s = mistralInstPattern.replace(s, "")
        s = geminiUnusedPattern.replace(s, "")

        // Mistral [TOOL_CALLS][...] opener: drop the opener, then balance
        // brackets in the JSON that follows to find the matching close.
        val opener = mistralToolCallsOpener.find(s)
        if (opener != null) {
            val openerStart = opener.range.first
            val openerEnd = opener.range.last + 1
            val rest = s.substring(openerEnd)
            var depth = 1
            var inString = false
            var escape = false
            var closeIdx: Int = -1
            for (i in rest.indices) {
                val ch = rest[i]
                if (escape) { escape = false; continue }
                if (ch == '\\') { escape = true; continue }
                if (ch == '"') { inString = !inString; continue }
                if (inString) continue
                if (ch == '[') depth++
                else if (ch == ']') {
                    depth--
                    if (depth == 0) { closeIdx = i; break }
                }
            }
            if (closeIdx >= 0) {
                s = s.substring(0, openerStart) + rest.substring(closeIdx + 1)
            } else {
                // No balanced close found — drop just the opener.
                s = s.removeRange(openerStart, openerEnd)
            }
        }
        return s
    }

    // MARK: - Provider tool-call XML strip

    // Capturing alternation of known tool-call wrapper names. The capture
    // group is the wrapper name so the closing-tag backref `\1` works.
    private const val TOOL_CALL_WRAPPER_NAME =
        "([A-Za-z][\\w-]*:tool_call|xai:function_call|xai:tool_call|tool_calls|tool_call|function_calls|antml:function_calls)"

    // DeepSeek's full-width-pipe XML tool-call blocks (`｜DSML｜…｜`).
    // Strip innermost first because Kotlin Regex doesn't support recursion.
    private val deepseekParameterBlockPattern: Regex =
        Regex("""<｜DSML｜parameter\b[^>]*>[\s\S]*?</｜DSML｜parameter>""")
    private val deepseekInvokeBlockPattern: Regex =
        Regex("""<｜DSML｜invoke\b[^>]*>[\s\S]*?</｜DSML｜invoke>""")
    private val deepseekFunctionCallsBlockPattern: Regex =
        Regex("""<｜DSML｜function_calls\b[^>]*>[\s\S]*?</｜DSML｜function_calls>""")

    // Matches complete <wrapper …>…</wrapper> tool-call blocks.
    private val toolCallBlockPattern: Regex =
        Regex("""<($TOOL_CALL_WRAPPER_NAME)\b[^>]*>[\s\S]*?</\1>""", RegexOption.IGNORE_CASE)

    // Some models emit malformed markup like
    // `minimax:tool_call <invoke …>…</invoke> </minimax:tool_call>` —
    // the opener is bare text, not enclosed in <>. Match the bare opener
    // plus everything up to and including the matching closing tag.
    private val bareOpenerToClosePattern: Regex =
        Regex(
            """(?:^|[^\w-])($TOOL_CALL_WRAPPER_NAME)\b[^<]*<[^>]*>[\s\S]*?</\1>""",
            RegexOption.IGNORE_CASE,
        )

    // Matches bare <invoke …>…</invoke> blocks (no enclosing wrapper).
    // Require a real closing tag (not self-closing />) so user code
    // snippets like `<invoke name="real" />` aren't erased.
    private val invokeBlockPattern: Regex =
        Regex(
            """<invoke\b(?:"[^"]*"|'[^']*'|[^'">])*>(?!/)[\s\S]*?</invoke>""",
            RegexOption.IGNORE_CASE,
        )

    // Unclosed wrapper mid-stream — drop everything from the tag on.
    private val openToolCallPattern: Regex =
        Regex("""<($TOOL_CALL_WRAPPER_NAME)\b[^>]*>[\s\S]*$""", RegexOption.IGNORE_CASE)

    // Unclosed <invoke …> mid-stream.
    private val openInvokePattern: Regex =
        Regex("""<invoke\b[^>]*[^/>]>[\s\S]*$""", RegexOption.IGNORE_CASE)

    // Unclosed bare wrapper <…> opener mid-stream.
    private val openBareOpenerPattern: Regex =
        Regex(
            """(?:^|[^\w-])($TOOL_CALL_WRAPPER_NAME)\s*(?=<[^>]*>[\s\S]*$)""",
            RegexOption.IGNORE_CASE,
        )

    // Partial trailing tag (e.g. <minimax:tool_call or <invoke ) while
    // still streaming. Last character must not be / so a complete
    // self-closing tag isn't mistaken for an unclosed opener.
    private val partialToolCallPattern: Regex =
        Regex("""<($TOOL_CALL_WRAPPER_NAME)\b[^>]*[^/>]$""", RegexOption.IGNORE_CASE)
    private val partialInvokePattern: Regex =
        Regex("""<invoke\b[^>]*[^/>]$""", RegexOption.IGNORE_CASE)

    /** Strip leaked provider tool-call XML from raw model output. */
    fun stripToolCallXml(raw: String): String {
        if (raw.isEmpty()) return raw
        var s = raw

        // DeepSeek's full-width-pipe ｜DSML｜…｜ blocks first, innermost
        // → outermost.
        s = deepseekParameterBlockPattern.replace(s, "")
        s = deepseekInvokeBlockPattern.replace(s, "")
        s = deepseekFunctionCallsBlockPattern.replace(s, "")
        s = toolCallBlockPattern.replace(s, "")
        s = bareOpenerToClosePattern.replace(s, "")
        s = invokeBlockPattern.replace(s, "")

        val openBlock = openToolCallPattern.find(s)
        if (openBlock != null) {
            s = s.substring(0, openBlock.range.first)
        } else {
            val bareOpener = openBareOpenerPattern.find(s)
            if (bareOpener != null) {
                // Drop from the captured wrapper name onward (group 1).
                val wrapperName = bareOpener.groupValues[1]
                val startInString = s.indexOf(wrapperName, bareOpener.range.first)
                if (startInString >= 0) {
                    s = s.substring(0, startInString)
                }
            } else {
                val openInvoke = openInvokePattern.find(s)
                if (openInvoke != null) {
                    s = s.substring(0, openInvoke.range.first)
                } else {
                    val partialTool = partialToolCallPattern.find(s)
                    if (partialTool != null) {
                        s = s.substring(0, partialTool.range.first)
                    } else {
                        val partialInvoke = partialInvokePattern.find(s)
                        if (partialInvoke != null) {
                            s = s.substring(0, partialInvoke.range.first)
                        }
                    }
                }
            }
        }
        return s
    }

    private fun tidy(text: String): String {
        // Trim and collapse 3+ consecutive newlines to 2.
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return trimmed
        return trimmed.replace(Regex("""\n{3,}"""), "\n\n")
    }
}
