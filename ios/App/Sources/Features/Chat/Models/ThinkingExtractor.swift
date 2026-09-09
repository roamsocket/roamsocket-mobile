import Foundation

/// Pulls model reasoning out of assistant text that wraps it in
/// `<think>…</think>` (or `<thinking>…</thinking>`) tags so the UI can
/// show it as a collapsible block instead of raw markup.
///
/// Also strips leaked provider tool-call XML (`minimax:tool_call`,
/// `function_calls`, bare `<invoke …>` blocks) so raw markup never reaches
/// the chat bubble when the model emits tool calls the iOS client doesn't
/// actually parse on the chat path.
enum ThinkingExtractor {
    struct Result: Equatable {
        /// Inner reasoning text. Non-nil when thinking tags were detected
        /// (empty string while streaming an open tag with no body yet).
        var thinking: String?
        /// Original string with thinking tags removed (trimmed).
        var content: String
        /// Open thinking tag has not been closed yet (streaming / incomplete).
        var isThinkingOpen: Bool
    }

    /// Alternation of tag names treated as reasoning/scratch containers.
    /// Inlined into the four tag patterns below — repeating the pattern
    /// verbatim means we don't need a backref and both open and close
    /// always match.
    ///
    /// Coverage:
    /// - `think`/`thinking`/`reasoning`/`reflection`/`thought`/`analysis`/
    ///   `scratch_pad` — generic reasoning tags emitted by Claude 4,
    ///   Qwen3, DeepSeek R1, Hermes 4, Phi-4 fine-tunes, RAG agents.
    /// - `antml:*` — Anthropic's namespaced reasoning containers
    ///   (Opus 5 leak, legacy antml prompt format).
    /// - `xai:reasoning` / `xai:thinking` — Grok 3 / Grok 4 reasoning
    ///   blocks. Grok wraps the model's scratch reasoning in
    ///   `<xai:reasoning>…</xai:reasoning>` and the final answer in
    ///   `<xai:thinking>` is rare but observed in previews.
    private static let thinkingTagNames =
        "think|thinking|reasoning|reflection|thought|analysis|scratch_pad|antml:thinking|antml:reasoning|antml:reflection|antml:thought|antml:analysis|xai:reasoning|xai:thinking"

    /// Paired tags; multi-line body. Case-insensitive tag name.
    /// Covers `think`/`thinking` plus a handful of variants emitted by
    /// different reasoning models (Anthropic Opus 5 leak, Phi-4 fine-tunes,
    /// RAG agents, Hermes 4 scratch pad, etc.).
    private static let pairedPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<(\(thinkingTagNames))\\b[^>]*>([\\s\\S]*?)</\\1>",
            options: [.caseInsensitive]
        )
    }()

    /// Unclosed open tag (e.g. still streaming). Captures everything after it.
    private static let openOnlyPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<(\(thinkingTagNames))\\b[^>]*>([\\s\\S]*)$",
            options: [.caseInsensitive]
        )
    }()

    /// Partial open tag at end of stream (`<thi`, `<think`, `<thinking ` …).
    private static let incompleteOpenPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<(\(thinkingTagNames))\\b[^>]*$",
            options: [.caseInsensitive]
        )
    }()

    /// Stray open/close tags left after primary extraction.
    private static let residualTagPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "</?(\(thinkingTagNames))\\b[^>]*>",
            options: [.caseInsensitive]
        )
    }()

    /// Kept as a cleanup fallback for malformed/nested Anthropic-style
    /// namespaced reasoning containers. Well-formed tags are extracted by the
    /// paired thinking pattern above so their body is preserved in `thinking`.
    private static let antmlThinkingPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<antml:(?:thinking|reasoning|reflection|thought|analysis)\\b[^>]*>[\\s\\S]*?</antml:(?:thinking|reasoning|reflection|thought|analysis)>",
            options: [.caseInsensitive]
        )
    }()

    static func extract(from raw: String) -> Result {
        guard !raw.isEmpty else {
            return Result(thinking: nil, content: raw, isThinkingOpen: false)
        }

        var thinkingParts: [String] = []
        var stripped = raw
        var sawThinkingTags = false
        var isThinkingOpen = false

        let full = NSRange(stripped.startIndex..., in: stripped)
        let matches = pairedPattern.matches(in: stripped, options: [], range: full)
        if !matches.isEmpty {
            sawThinkingTags = true
            thinkingParts = matches.compactMap { match in
                guard match.numberOfRanges > 2,
                      let r = Range(match.range(at: 2), in: stripped) else { return nil }
                let part = String(stripped[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                return part.isEmpty ? nil : part
            }
            stripped = pairedPattern.stringByReplacingMatches(
                in: stripped,
                options: [],
                range: full,
                withTemplate: ""
            )
        }

        let afterPairs = NSRange(stripped.startIndex..., in: stripped)
        if let open = openOnlyPattern.firstMatch(in: stripped, options: [], range: afterPairs),
           open.numberOfRanges > 2,
           let innerRange = Range(open.range(at: 2), in: stripped),
           let outerRange = Range(open.range, in: stripped) {
            sawThinkingTags = true
            isThinkingOpen = true
            let part = String(stripped[innerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { thinkingParts.append(part) }
            stripped = String(stripped[..<outerRange.lowerBound])
        } else if let incomplete = incompleteOpenPattern.firstMatch(
            in: stripped, options: [], range: afterPairs
        ), let outerRange = Range(incomplete.range, in: stripped) {
            // Streaming mid-tag (`…\n<th` / `…<think`) — hide it and show Thinking…
            sawThinkingTags = true
            isThinkingOpen = true
            stripped = String(stripped[..<outerRange.lowerBound])
        }

        // Orphan close/open tags must never leak into the bubble.
        let residualRange = NSRange(stripped.startIndex..., in: stripped)
        if residualTagPattern.firstMatch(in: stripped, options: [], range: residualRange) != nil {
            sawThinkingTags = true
            stripped = residualTagPattern.stringByReplacingMatches(
                in: stripped,
                options: [],
                range: residualRange,
                withTemplate: ""
            )
        }

        let thinkingJoined = thinkingParts.joined(separator: "\n\n")
        // Non-nil whenever tags were present — empty body still means "thinking UI".
        let thinking: String? = sawThinkingTags ? thinkingJoined : nil

        let content = tidy(stripped)
        return Result(thinking: thinking, content: content, isThinkingOpen: isThinkingOpen)
    }

    /// Visible answer only — thinking markup removed. Use for commit subjects,
    /// titles, and any plain-text sink that must not see `<think>` tokens.
    static func plainVisibleText(from raw: String) -> String {
        extract(from: raw).content
    }

    // MARK: - Provider control-token strip

    /// Strips leaked tokenizer special tokens that should never reach the
    /// chat bubble. Covers Llama 3 (`<|eot_id|>`, `<|eom_id|>`, …), Qwen
    /// (`<|im_start|>` / `<|im_end|>`), Phi (`<|user|>` / `<|assistant|>`
    /// / `<|end|>`), Gemma (`<start_of_turn>` / `<end_of_turn>`), and a
    /// handful of others. Mistral's `[INST]…[/INST]` brackets are handled
    /// separately because they use a different syntax.
    private static let controlTokenPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<\\|\\s*(?:begin_of_text|end_of_text|start_header_id|end_header_id|eot_id|eom_id|python_tag|user|assistant|system|end|endoftext|im_start|im_end|tool_call_start|tool_call_end|tool_call_argument_begin|tool_call_argument_end|ref|box_start|box_end|image_pad|object_ref_start|object_ref_end|patch|patch_start|patch_end|quad_start|quad_end|vision_start|vision_end|place_holder|constrain|/constrain|reasoning|/reasoning)\\s*\\|>",
            options: [.caseInsensitive]
        )
    }()

    /// Gemma-family plain-text turn markers.
    private static let gemmaTurnPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "</?start_of_turn\\b[^>]*>|</?end_of_turn\\b[^>]*>|<\\|turn\\|>|<turn\\|>",
            options: [.caseInsensitive]
        )
    }()

    /// Mistral `[INST]…[/INST]` orphan brackets. Matches both opening and
    /// closing tags so any leftover marker is removed; legitimate
    /// user-quoted `[INST]` text is preserved unless the model
    /// accidentally emits the exact pair.
    private static let mistralInstPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "\\[/?INST\\]",
            options: []
        )
    }()

    /// Llama 2 chat template system block: `<<SYS>>…<</SYS>>`. Some
    /// Llama 2 fine-tunes emit the wrapper in the visible answer
    /// instead of behind the scenes; the `</s>` end-of-sentence token
    /// and `[INST]` style brackets are also sometimes visible. Strip
    /// the system block outright — its content is duplicated by the
    /// system prompt we already send, so nothing of value is lost.
    private static let llama2SystemBlockPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<<SYS>>[\\s\\S]*?<</SYS>>",
            options: []
        )
    }()

    /// `</s>` end-of-sentence token leaked by Llama-family chat
    /// models. Standalone (not inside a code snippet) so we don't
    /// touch user code.
    private static let endOfSentenceTokenPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "</s>",
            options: []
        )
    }()

    /// HTML comment strip. Some Claude 3.7 Sonnet and Llama 3.3
    /// fine-tunes leak reasoning as `<!-- reasoning … -->`. Block
    /// comments can span newlines and be arbitrarily long.
    private static let htmlCommentPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<!--[\\s\\S]*?-->",
            options: []
        )
    }()

    /// Llama 3.1 / some Grok 3 fine-tunes wrap reasoning in special
    /// tokens: `<|reasoning|>…<|/reasoning|>`. The body between the
    /// tokens is the model's scratch reasoning. We strip the entire
    /// block (body + wrappers) so the reasoning never reaches the
    /// chat bubble; the `controlTokenPattern` falls back to removing
    /// the individual tokens when the block is malformed / unclosed.
    private static let llamaReasoningBlockPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<\\|reasoning\\|>[\\s\\S]*?<\\|/reasoning\\|>",
            options: [.caseInsensitive]
        )
    }()

    /// ChatGLM / Qwen-Chat output wrapper. The model emits the
    /// visible answer inside `<output>…</output>` (used to disambiguate
    /// from system context). The wrapper itself has no value to the
    /// user; strip the entire block.
    private static let chatGlmOutputPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<output\\b[^>]*>[\\s\\S]*?</output>",
            options: [.caseInsensitive]
        )
    }()

    /// `[SYSTEM_PROMPT]` orphan marker some Mistral 3 fine-tunes emit
    /// when the system prompt wasn't fully suppressed. Strip the
    /// marker plus everything up to the next blank line or the end
    /// of the reply — the body is duplicate system context.
    private static let systemPromptLeakPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "\\[SYSTEM_PROMPT\\][\\s\\S]*?(?=\\n\\s*\\n|$)",
            options: [.caseInsensitive]
        )
    }()

    /// Mistral `[TOOL_CALLS][` opener — strip the opening bracket sequence
    /// plus the immediately-following JSON array up to the matching `]`.
    /// No closing tag in Mistral's format; we balance brackets inside the
    /// match to avoid eating prose.
    private static let mistralToolCallsOpener: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "\\[TOOL_CALLS\\]\\[",
            options: []
        )
    }()

    /// `unusedNN>` placeholders Gemini sometimes leaks.
    private static let geminiUnusedPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<unused\\d+\\b[^>]*>",
            options: []
        )
    }()

    /// LFM2's Pythonic tool-call wrapper. Tool calls are not executed by the
    /// chat path, so remove the complete block instead of exposing its syntax.
    private static let lfmToolCallPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<\\|tool_call_start\\|>[\\s\\S]*?<\\|tool_call_end\\|>",
            options: [.caseInsensitive]
        )
    }()

    /// Gemma 4's tool-call wrapper uses a delimiter with a pipe on each side.
    private static let gemma4ToolCallPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<\\|tool_call>[\\s\\S]*?<tool_call\\|>",
            options: [.caseInsensitive]
        )
    }()

    /// Mistral 3's tool-call response starts with `[TOOL_CALLS]` and is
    /// terminal output, so discard the marker and everything that follows.
    private static let mistralToolCallPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "\\[TOOL_CALLS\\][\\s\\S]*$",
            options: [.caseInsensitive]
        )
    }()

    /// Gemma's function-call wrapper (used by Gemma 3 tool-capable models).
    private static let gemmaToolCallPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<start_function_call>[\\s\\S]*?<end_function_call>",
            options: [.caseInsensitive]
        )
    }()

    /// Anthropic legacy single-invoke wrapper. The newer Anthropic
    /// wire format is JSON `tool_use` blocks (handled at the API
    /// layer), but some Claude 3 Opus / 3.5 Sonnet fine-tunes still
    /// leak `<antml:invoke name="…">…</antml:invoke>` calls into the
    /// visible text. The chat path doesn't parse them, so strip.
    private static let antmlInvokePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<antml:invoke\\b(?:\"[^\"]*\"|'[^']*'|[^'\">])*>(?!/)[\\s\\S]*?</antml:invoke>",
            options: [.caseInsensitive]
        )
    }()

    /// Strip leaked tokenizer / turn-marker control tokens. Pure function.
    static func stripControlTokens(from raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw
        let blockPatterns: [NSRegularExpression] = [
            lfmToolCallPattern,
            gemma4ToolCallPattern,
            mistralToolCallPattern,
            gemmaToolCallPattern,
            // New in this revision: provider-specific output wrappers
            // that should never reach the chat bubble. The Llama 3.1
            // reasoning block goes here so the entire `<|reasoning|>…
            // <|/reasoning|>` pair is dropped (not just the wrappers
            // — leaving the body bare would surface reasoning as
            // plain text in the chat bubble).
            llama2SystemBlockPattern,
            llamaReasoningBlockPattern,
            chatGlmOutputPattern,
            htmlCommentPattern,
            systemPromptLeakPattern,
        ]
        for pattern in blockPatterns {
            let range = NSRange(s.startIndex..., in: s)
            s = pattern.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        }
        let full = NSRange(s.startIndex..., in: s)
        s = controlTokenPattern.stringByReplacingMatches(in: s, options: [], range: full, withTemplate: "")
        let r1 = NSRange(s.startIndex..., in: s)
        s = gemmaTurnPattern.stringByReplacingMatches(in: s, options: [], range: r1, withTemplate: "")
        let r2 = NSRange(s.startIndex..., in: s)
        s = mistralInstPattern.stringByReplacingMatches(in: s, options: [], range: r2, withTemplate: "")
        let r3 = NSRange(s.startIndex..., in: s)
        s = geminiUnusedPattern.stringByReplacingMatches(in: s, options: [], range: r3, withTemplate: "")
        let r3a = NSRange(s.startIndex..., in: s)
        s = endOfSentenceTokenPattern.stringByReplacingMatches(in: s, options: [], range: r3a, withTemplate: "")
        // Mistral `[TOOL_CALLS][...]` opener: drop the opener, then balance
        // brackets in the JSON that follows to find the matching close.
        let r4 = NSRange(s.startIndex..., in: s)
        if let open = mistralToolCallsOpener.firstMatch(in: s, options: [], range: r4) {
            // Search the remainder after the opener for the matching `]`.
            let openerEnd = open.range.location + open.range.length
            guard openerEnd <= s.utf16.count else { return s }
            let afterOpener = s.utf16.index(s.utf16.startIndex, offsetBy: openerEnd)
            let afterOpenerIdx = afterOpener.samePosition(in: s) ?? s.endIndex
            let openerStart = s.utf16.index(s.utf16.startIndex, offsetBy: open.range.location)
            let openerStartIdx = openerStart.samePosition(in: s) ?? s.startIndex
            let rest = s[afterOpenerIdx...]
            var depth = 1
            var inString = false
            var escape = false
            var closeIdx: String.Index? = nil
            for idx in rest.indices {
                let ch = rest[idx]
                if escape { escape = false; continue }
                if ch == "\\" { escape = true; continue }
                if ch == "\"" { inString.toggle(); continue }
                if inString { continue }
                if ch == "[" { depth += 1 }
                else if ch == "]" {
                    depth -= 1
                    if depth == 0 {
                        closeIdx = idx
                        break
                    }
                }
            }
            if depth == 0, let ci = closeIdx {
                let endIdx = rest.index(after: ci)
                let prefix = String(s[..<openerStartIdx])
                let suffix = String(rest[endIdx...])
                s = prefix + suffix
            } else if let r = Range(open.range, in: s) {
                // No balanced close found — drop just the opener.
                s.replaceSubrange(r, with: "")
            }
        }
        return s
    }

    // MARK: - Provider tool-call XML strip

    /// Capturing alternation of known tool-call wrapper names. MiniMax M2
    /// uses `minimax:tool_call`, Anthropic's legacy XML uses
    /// `function_calls` / `antml:function_calls` / `antml:invoke`,
    /// xAI uses `xai:function_call` / `xai:tool_call` / `xai:tool_calls`,
    /// Hermes uses singular `tool_call`, and some providers use bare
    /// `tool_calls`. Capturing so the closing-tag backreference `\1`
    /// works.
    ///
    /// DeepSeek's `｜DSML｜function_calls｜` form (full-width `｜`, U+FF5C)
    /// is handled separately by `deepseekBlockPattern` because the
    /// opening / closing tag names are themselves bracketed in `｜` and
    /// don't backref cleanly against ASCII tag names.
    private static let toolCallWrapperName =
        #"([A-Za-z][\w-]*:tool_call|xai:function_call|xai:tool_call|xai:tool_calls|tool_calls|tool_call|function_calls|antml:function_calls)"#

    /// DeepSeek's full-width-pipe XML tool-call blocks. Strip in three
    /// passes — innermost first — because NSRegularExpression doesn't
    /// support recursion, and a single pass with `function_calls|invoke|parameter`
    /// as the closing alternation would non-greedily stop at the first
    /// matching closer, leaving the outer wrapper's close tag behind.
    private static let deepseekParameterBlockPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<｜DSML｜parameter\\b[^>]*>[\\s\\S]*?</｜DSML｜parameter>",
            options: []
        )
    }()
    private static let deepseekInvokeBlockPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<｜DSML｜invoke\\b[^>]*>[\\s\\S]*?</｜DSML｜invoke>",
            options: []
        )
    }()
    private static let deepseekFunctionCallsBlockPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<｜DSML｜function_calls\\b[^>]*>[\\s\\S]*?</｜DSML｜function_calls>",
            options: []
        )
    }()

    /// Matches complete `<wrapper …>…</wrapper>` tool-call blocks.
    private static let toolCallBlockPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<\(toolCallWrapperName)\\b[^>]*>[\\s\\S]*?</\\1>",
            options: [.caseInsensitive]
        )
    }()

    /// Some models emit malformed markup like
    /// `minimax:tool_call <invoke …>…</invoke> </minimax:tool_call>` —
    /// the opener is bare text, not enclosed in `<>`. Match the bare opener
    /// plus everything up to and including the matching closing tag.
    /// The inner `<invoke>` block is removed separately by `invokeBlockPattern`.
    private static let bareOpenerToClosePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "(^|[^\\w-])(\(toolCallWrapperName))\\b[^<]*<[^>]*>[\\s\\S]*?</\\2>",
            options: [.caseInsensitive]
        )
    }()

    /// Matches bare `<invoke …>…</invoke>` blocks (no enclosing wrapper).
    /// Require a real closing tag (not self-closing `/>`) so user code
    /// snippets like `<invoke name="real" />` aren't erased.
    private static let invokeBlockPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<invoke\\b(?:\"[^\"]*\"|'[^']*'|[^'\">])*>(?!/)[\\s\\S]*?</invoke>",
            options: [.caseInsensitive]
        )
    }()

    /// Unclosed wrapper mid-stream — drop everything from the tag on.
    private static let openToolCallPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<\(toolCallWrapperName)\\b[^>]*>[\\s\\S]*$",
            options: [.caseInsensitive]
        )
    }()

    /// Unclosed `<invoke …>` mid-stream. Same self-closing guard as the
    /// partial pattern so user code snippets aren't erased.
    private static let openInvokePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<invoke\\b[^>]*[^/>]>[\\s\\S]*$",
            options: [.caseInsensitive]
        )
    }()

    /// Unclosed bare `wrapper <…>` opener mid-stream — drop from the opener on.
    private static let openBareOpenerPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "(^|[^\\w-])(\(toolCallWrapperName))\\s*(?=<[^>]*>[\\s\\S]*$)",
            options: [.caseInsensitive]
        )
    }()

    /// Partial trailing tag (e.g. `<minimax:tool_call` or `<invoke `) while
    /// still streaming. Last character must not be `/` so a complete
    /// self-closing tag (`<invoke name="x" />`) in user code isn't mistaken
    /// for an unclosed opener.
    private static let partialToolCallPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<\(toolCallWrapperName)\\b[^>]*[^/>]$",
            options: [.caseInsensitive]
        )
    }()
    private static let partialInvokePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<invoke\\b[^>]*[^/>]$",
            options: [.caseInsensitive]
        )
    }()

    /// Strip leaked provider tool-call XML from raw model output.
    /// Pure function; safe to call on every reply / streaming chunk.
    static func stripToolCallXML(from raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw
        let full = NSRange(s.startIndex..., in: s)
        // Anthropic legacy `<antml:invoke>` blocks first. They're
        // well-formed (open + close tag) but not in the
        // `toolCallWrapperName` alternation (the wrapper name is
        // `invoke`, not `tool_call` / `function_calls`), so they need
        // their own pattern.
        s = antmlInvokePattern.stringByReplacingMatches(
            in: s, options: [], range: full, withTemplate: ""
        )
        let rAnti = NSRange(s.startIndex..., in: s)
        // DeepSeek's full-width-pipe `｜DSML｜…｜` blocks first, innermost
        // → outermost, so the inner `</｜…｜>` closer doesn't terminate
        // a non-greedy outer match prematurely.
        s = deepseekParameterBlockPattern.stringByReplacingMatches(
            in: s, options: [], range: rAnti, withTemplate: ""
        )
        let r1 = NSRange(s.startIndex..., in: s)
        s = deepseekInvokeBlockPattern.stringByReplacingMatches(
            in: s, options: [], range: r1, withTemplate: ""
        )
        let r2 = NSRange(s.startIndex..., in: s)
        s = deepseekFunctionCallsBlockPattern.stringByReplacingMatches(
            in: s, options: [], range: r2, withTemplate: ""
        )
        let r3 = NSRange(s.startIndex..., in: s)
        s = toolCallBlockPattern.stringByReplacingMatches(
            in: s, options: [], range: r3, withTemplate: ""
        )
        let afterBlocks = NSRange(s.startIndex..., in: s)
        s = bareOpenerToClosePattern.stringByReplacingMatches(
            in: s, options: [], range: afterBlocks, withTemplate: ""
        )
        let afterBare = NSRange(s.startIndex..., in: s)
        s = invokeBlockPattern.stringByReplacingMatches(
            in: s, options: [], range: afterBare, withTemplate: ""
        )
        let afterInline = NSRange(s.startIndex..., in: s)
        if let open = openToolCallPattern.firstMatch(in: s, options: [], range: afterInline),
           let outer = Range(open.range, in: s) {
            s = String(s[..<outer.lowerBound])
        } else if let bare = openBareOpenerPattern.firstMatch(
            in: s, options: [], range: afterInline
        ), let opener = Range(bare.range(at: 2), in: s) {
            s = String(s[..<opener.lowerBound])
        } else {
            let r = NSRange(s.startIndex..., in: s)
            if let open = openInvokePattern.firstMatch(in: s, options: [], range: r),
               let outer = Range(open.range, in: s) {
                s = String(s[..<outer.lowerBound])
            } else if let partial = partialToolCallPattern.firstMatch(
                in: s, options: [], range: r
            ), let outer = Range(partial.range, in: s) {
                s = String(s[..<outer.lowerBound])
            } else if let partial = partialInvokePattern.firstMatch(
                in: s, options: [], range: r
            ), let outer = Range(partial.range, in: s) {
                s = String(s[..<outer.lowerBound])
            }
        }
        return s
    }

    /// First non-empty plain line after stripping thinking (and quotes).
    /// Returns nil when nothing usable remains.
    static func firstPlainLine(from raw: String) -> String? {
        let content = plainVisibleText(from: raw)
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !looksLikeThinkingMarkup($0) }
        guard var line = lines.first else { return nil }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !line.isEmpty, !looksLikeThinkingMarkup(line) else { return nil }
        return line
    }

    private static func looksLikeThinkingMarkup(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.hasPrefix("<think") || lower.hasPrefix("</think")
            || lower == "<thinking>" || lower == "</thinking>"
            || lower.hasPrefix("<reason") || lower.hasPrefix("</reason")
            || lower.hasPrefix("<reflect") || lower.hasPrefix("</reflect")
            || lower.hasPrefix("<thought") || lower.hasPrefix("</thought")
            || lower.hasPrefix("<analy") || lower.hasPrefix("</analy")
            || lower.hasPrefix("<scratch_pad") || lower.hasPrefix("</scratch_pad")
            || lower.hasPrefix("<antml:think") || lower.hasPrefix("</antml:think")
            || lower.hasPrefix("<xai:reason") || lower.hasPrefix("</xai:reason")
            || lower.hasPrefix("<xai:think") || lower.hasPrefix("</xai:think")
        {
            return true
        }
        return false
    }

    private static func tidy(_ stripped: String) -> String {
        stripControlTokens(from: stripToolCallXML(from: stripped))
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Combined cleaner: thinking-tag extraction, then all provider-specific
    /// markup stripping. Use this when you only want the cleaned visible
    /// text (chat bubble, commit message, title, etc.) and don't care
    /// about the structured `Result`.
    static func cleaned(_ raw: String) -> String {
        var s = extract(from: raw).content
        s = stripControlTokens(from: s)
        s = antmlThinkingPattern.stringByReplacingMatches(
            in: s,
            options: [],
            range: NSRange(s.startIndex..., in: s),
            withTemplate: ""
        )
        return s
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }
}
