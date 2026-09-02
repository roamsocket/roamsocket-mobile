import Foundation

/// `AgentLLM` implementation that talks to any OpenAI-compatible
/// `/v1/chat/completions` endpoint with streaming + tool calls.
/// Used for OpenAI, Groq, OpenRouter, xAI, Mistral, and custom
/// OpenAI-compatible endpoints (the bulk of the app's provider
/// list).
///
/// Wire format: standard OpenAI Chat Completions. The `messages`
/// array alternates `user` / `assistant` (with optional
/// `tool_calls`) / `tool` (with `tool_call_id`). Tool calls
/// stream as a sequence of `delta.tool_calls[i]` chunks where
/// each chunk may carry `id`, `function.name`, and a partial
/// `function.arguments` JSON string. We accumulate the arguments
/// per tool index, parse to a JSON object on `finish_reason:
/// "tool_calls"`, and emit the corresponding `AgentLLMEvent`.
public actor OpenAICompatibleAgentLLM: AgentLLM {
    // Set once in init, never mutated, so expose nonisolated for
    // tests and call sites that need to inspect configuration
    // (e.g. the regression test that pins `.minimax` to
    // `api.minimax.io` rather than the OpenAI default).
    nonisolated let baseURL: URL
    nonisolated let modelID: String
    nonisolated let apiKey: String
    nonisolated let maxTokens: Int
    nonisolated let session: URLSession
    /// When `true`, `stream(...)` issues a single non-streaming
    /// POST and yields the full assistant turn as a single
    /// `textDelta` (followed by `toolCall*` events and `.stop`).
    /// Some OpenAI-compatible providers — most notably MiniMax
    /// — accept the request but return an empty streaming
    /// response when `tools` is set, leaving the agent pinned
    /// at "Working". The desktop server's E2B runner and the
    /// iOS chat composer both use the non-streaming code path
    /// for the same reason. Streaming stays the default for
    /// providers that handle it well; opt in per-provider
    /// from `AgentLLMFactory`.
    nonisolated let useNonStreaming: Bool

    public init(
        apiKey: String,
        modelID: String,
        baseURL: URL,
        maxTokens: Int = 4096,
        useNonStreaming: Bool = false,
    ) {
        self.apiKey = apiKey
        self.modelID = modelID
        self.baseURL = baseURL
        self.maxTokens = maxTokens
        self.session = URLSession.shared
        self.useNonStreaming = useNonStreaming
    }

    public nonisolated func stream(
        system: String,
        messages: [AgentLLMMessage],
        tools: [AgentLLMTool],
        maxTokens: Int,
    ) -> AsyncThrowingStream<AgentLLMEvent, Error> {
        // Non-streaming path. Some OpenAI-compatible providers
        // (notably MiniMax) accept the request but return an
        // empty streaming response when `tools` is set. Match
        // the desktop server's E2B runner and the chat
        // composer's working path: one POST, full JSON, emit
        // the text + tool calls as a single batch.
        if useNonStreaming {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await runNonStreaming(
                            system: system,
                            messages: messages,
                            tools: tools,
                            maxTokens: maxTokens,
                            continuation: continuation
                        )
                        continuation.yield(.stop)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        let body = Self.buildBody(
            system: system,
            messages: messages,
            tools: tools,
            modelID: modelID,
            maxTokens: maxTokens
        )

        return AsyncThrowingStream<AgentLLMEvent, Error> { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await post(body: body)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        var bodyData = Data()
                        do {
                            for try await byte in bytes.prefix(1024) {
                                bodyData.append(byte)
                            }
                        } catch {
                            // Body preview is best-effort; fall
                            // through with what we have.
                        }
                        let body = String(data: bodyData, encoding: .utf8) ?? ""
                        throw OpenAICompatibleError.httpStatus(code, body)
                    }
                    // Cap the wall-clock duration of the stream so
                    // a model that opens a chunked response but
                    // never sends `[DONE]` (or `finish_reason`) —
                    // usually a provider whose tool-calling format
                    // is incomplete or unsupported — doesn't pin
                    // the runner at "thinking…" forever. 5 minutes
                    // is generous for a single agent turn; the
                    // runner can always issue a fresh request.
                    let deadline = Date().addingTimeInterval(Self.maxStreamSeconds)
                    var dataBuffer = ""
                    // Per OpenAI streaming: each SSE event is
                    // `data: {json}\n\n` (no `event:` line). The
                    // terminating chunk is `data: [DONE]\n\n`.
                    var inToolCalls: [Int: ToolCallAcc] = [:]
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if Date() > deadline {
                            throw OpenAICompatibleError.streamTimeout(
                                elapsed: Self.maxStreamSeconds
                            )
                        }
                        if line.isEmpty {
                            if !dataBuffer.isEmpty {
                                let trimmed = dataBuffer.trimmingCharacters(in: .whitespaces)
                                if trimmed == "[DONE]" {
                                    break
                                }
                                if Self.parseChunk(
                                    trimmed,
                                    acc: &inToolCalls,
                                    continuation: continuation
                                ) {
                                    break
                                }
                            }
                            dataBuffer = ""
                            continue
                        }
                        if line.hasPrefix("data:") {
                            dataBuffer = String(line.dropFirst("data:".count))
                                .trimmingCharacters(in: .whitespaces)
                        }
                    }
                    continuation.yield(.stop)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// One-shot, non-streaming POST. Parses the full Chat
    /// Completions response and yields the same event stream
    /// the streaming path would have produced, so the runner
    /// (and tests) don't need to special-case it.
    private nonisolated func runNonStreaming(
        system: String,
        messages: [AgentLLMMessage],
        tools: [AgentLLMTool],
        maxTokens: Int,
        continuation: AsyncThrowingStream<AgentLLMEvent, Error>.Continuation,
    ) async throws {
        // Same body shape as the streaming path, minus the
        // `stream: true` flag.
        var body = Self.buildBody(
            system: system,
            messages: messages,
            tools: tools,
            modelID: modelID,
            maxTokens: maxTokens
        )
        body.removeValue(forKey: "stream")

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OpenAICompatibleError.httpStatus(code, bodyText)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else {
            throw OpenAICompatibleError.decoding(
                "non-streaming response was not a recognised Chat Completions payload"
            )
        }
        // Tool calls. Same `{id, type, function: {name, arguments}}`
        // shape as the streaming `delta.tool_calls`, just on the
        // final message instead of per-chunk.
        let toolCalls = message["tool_calls"] as? [[String: Any]]
        let hasStandardToolCalls = !(toolCalls?.isEmpty ?? true)
        if hasStandardToolCalls, let toolCalls {
            for tc in toolCalls {
                let id = tc["id"] as? String ?? ""
                let fn = tc["function"] as? [String: Any]
                let name = fn?["name"] as? String ?? ""
                let arguments = fn?["arguments"] as? String ?? ""
                if id.isEmpty || name.isEmpty { continue }
                continuation.yield(.toolCallStart(
                    id: id, name: name, input: .init(raw: .object([:]))
                ))
                if !arguments.isEmpty {
                    continuation.yield(.toolCallInputDelta(
                        id: id, partialJSON: arguments
                    ))
                }
                continuation.yield(.toolCallEnd(id: id))
            }
        }
        // Text + thinking. Some OpenAI-compatible providers —
        // most notably MiniMax M3 — accept the request but
        // return tool calls as embedded text markup instead of
        // the `message.tool_calls` array, e.g.
        //   `<think>plan</think> [tool_call: run_shell]<command>ls /code</command>`
        // When the array is empty but the content looks like
        // that shape, parse it out and emit the same event
        // sequence the standard path would have produced. The
        // runner / dispatcher don't need to know the
        // difference; the tool call lands in `toolCalls` and
        // runs the same e2b sandbox tools either way.
        if let content = message["content"] as? String, !content.isEmpty {
            let parsed2 = Self.parseProviderTextToolCalls(content)
            if let thinking = parsed2.thinking, !thinking.isEmpty {
                continuation.yield(.thinkingDelta(text: thinking))
            }
            if !parsed2.content.isEmpty {
                continuation.yield(.textDelta(text: parsed2.content))
            }
            for call in parsed2.toolCalls {
                continuation.yield(.toolCallStart(
                    id: call.id, name: call.name, input: .init(raw: .object([:]))
                ))
                continuation.yield(.toolCallInputDelta(
                    id: call.id, partialJSON: call.argumentsJSON
                ))
                continuation.yield(.toolCallEnd(id: call.id))
            }
        }
        // Usage (cumulative on the final chunk for OpenAI; on
        // the message envelope for non-streaming). The shape
        // matches the streaming branch's usage forwarding.
        if let usage = parsed["usage"] as? [String: Any] {
            let input = usage["prompt_tokens"] as? Int ?? 0
            let output = usage["completion_tokens"] as? Int ?? 0
            if input > 0 || output > 0 {
                continuation.yield(.usage(inputTokens: input, outputTokens: output))
            }
        }
    }

    /// Wall-clock cap on a single streamed response. Most models
    /// finish a tool-using turn in under 90s; we add headroom
    /// for thinking / reasoning variants. Public so the runner
    /// (or future config) can read the default for known-slow
    /// models without changing the protocol surface.
    nonisolated public static let maxStreamSeconds: TimeInterval = 300

    /// Mutable accumulator for one in-flight tool call. The
    /// OpenAI stream gives us `id` on the first chunk, `name` on
    /// the first or second, and `arguments` as a growing
    /// partial-JSON string across many chunks.
    fileprivate struct ToolCallAcc {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    /// One parsed provider-text tool call. The arguments are
    /// pre-serialised to JSON so the existing
    /// `toolCallInputDelta(partialJSON:)` path can carry them
    /// without a second translation step.
    struct ProviderTextCall: Sendable {
        let id: String
        let name: String
        let argumentsJSON: String
    }

    /// Result of `parseProviderTextToolCalls`: reasoning text,
    /// cleaned visible content, and any extracted tool calls.
    struct ProviderTextResult: Sendable {
        let thinking: String?
        let content: String
        let toolCalls: [ProviderTextCall]
    }

    /// One line inside a tool-call body. Used by the key-value
    /// parser to mark which lines were consumed so the caller
    /// can strip them from the cleaned text.
    fileprivate struct KeyValueLine: Sendable {
        let range: Range<String.Index>
        let key: String
        let value: String
        let parsedJSON: Any?
    }

    /// Parse the body of MiniMax M3's newest shape: a *log* of
    /// an imagined shell run rather than a structured
    /// parameter list. The model writes:
    ///
    ///     [tool: ?] <command>
    ///     --- stdout ---
    ///     <fabricated output>
    ///     --- stderr ---
    ///     <fabricated error>
    ///
    /// and emits one such block per imagined call. Only the
    /// first line is real — the `--- stdout ---` / `--- stderr
    /// ---` sections are the model confabulating results the
    /// e2b sandbox has not actually produced. We extract the
    /// command, return it under the `command` key, and mark
    /// the whole block consumed so the visible text drops the
    /// fabricated output. The real e2b sandbox will produce
    /// the authoritative result on dispatch and the runner
    /// appends that to the transcript.
    ///
    /// The name field is irrelevant here — the dispatch
    /// decision is made by the marker (`[tool: ?]` defaults
    /// to `run_shell`). The body itself only contributes
    /// `command`.
    nonisolated static func parseLogStyleToolCallBody(_ raw: String)
        -> (input: [String: Any], consumed: [(Int, Int)])
    {
        let ns = raw as NSString
        let total = ns.length
        // First line: from index 0 to the first newline, or
        // the whole body if there is no newline. MiniMax
        // puts the command on the same line as the marker
        // (after a single space), so the first line of the
        // body is the command.
        let firstLineEnd: Int
        if total == 0 {
            firstLineEnd = 0
        } else {
            let nlRange = ns.range(of: "\n", range: NSRange(location: 0, length: total))
            firstLineEnd = nlRange.location == NSNotFound ? total : Int(nlRange.location)
        }
        let command = ns.substring(
            with: NSRange(location: 0, length: firstLineEnd)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Consume the whole block — the model's stdout /
        // stderr is fabrication. The e2b sandbox result
        // replaces it on the next dispatch.
        if total == 0 {
            return (["command": command], [])
        }
        return (["command": command], [(0, total)])
    }

    /// Parse a single tool-call body (the text between the
    /// `[tool_call: name]` opener and the next marker or end of
    /// text). Two shapes are supported; both come from MiniMax
    /// M3 at different temperatures:
    ///
    /// 1. **Tag shape** (the earlier format):
    ///    ```
    ///    <command>ls /code</command>
    ///    ```
    /// 2. **Key-value shape** (the newer format):
    ///    ```
    ///    id=call_cb7d56d06ce74debaa41963d
    ///    input={"command":"ls -la && echo \"-----\" && git log --oneline -10"}
    ///    ```
    ///
    /// For the key-value shape, the `input=` value is usually a
    /// JSON object that already matches the tool's parameter
    /// schema (MiniMax serialises the tool arguments as JSON
    /// in-line). When that value parses as a dictionary, the
    /// dictionary replaces the entire input map; otherwise it
    /// is stored under the `input` key.
    ///
    /// Returns the parsed input map and the
    /// `(start, length)` character-offset pairs in the input
    /// that were consumed (caller rebuilds the visible
    /// portion by skipping those slices). Character offsets
    /// (not `String.Index`) so the caller can rebuild a fresh
    /// String without index-sharing hazards.
    nonisolated static func parseToolCallBody(_ raw: String)
        -> (input: [String: Any], consumed: [(Int, Int)])
    {
        // Convert to NSString so we can use UTF-16 offsets
        // safely (every character in MiniMax tool-call bodies
        // is ASCII so this is character-exact too).
        let ns = raw as NSString
        let total = ns.length
        // 1. Tag shape. Walk the body and pull every
        //    `<param>value</param>` pair; record each open +
        //    close byte range so the caller can strip it.
        var fromTags: [String: Any] = [:]
        var consumed: [(Int, Int)] = []
        var tagSearch = 0
        while tagSearch < total {
            // Find the next `<`.
            let openAngle = ns.range(of: "<", range: NSRange(location: tagSearch, length: total - tagSearch)).location
            if openAngle == NSNotFound { break }
            let afterOpen = openAngle + 1
            // Tag name: letters / digits / underscore / dash /
            // space. Read up to whitespace or `>`.
            var nameEnd = afterOpen
            while nameEnd < total {
                let c = ns.character(at: nameEnd)
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { break }
                if c == 0x3E /* `>` */ { break }
                if c == 0x2F /* `/` */ { break }
                nameEnd += 1
            }
            // Need the open angle to be followed by a real
            // tag name (at least one char) and then `>`.
            guard nameEnd > afterOpen,
                  nameEnd < total,
                  ns.character(at: nameEnd) == 0x3E
            else {
                tagSearch = openAngle + 1
                continue
            }
            let tagName = ns.substring(
                with: NSRange(location: afterOpen, length: nameEnd - afterOpen)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tagName.isEmpty else {
                tagSearch = openAngle + 1
                continue
            }
            // Find the next `<` for the close tag. We accept
            // whatever follows as the close — be lenient about
            // malformed names / whitespace.
            let closeSearchStart = nameEnd + 1
            guard closeSearchStart <= total else {
                tagSearch = nameEnd + 1
                continue
            }
            let closeAngle = ns.range(
                of: "<",
                range: NSRange(location: closeSearchStart, length: total - closeSearchStart)
            ).location
            // Determine the consumed end (the close tag's
            // closing `>`) or block.endIndex if there's no
            // close at all. Walk past any `</` and the rest
            // of the close tag to find the `>`.
            var consumedEnd: Int
            if closeAngle == NSNotFound {
                consumedEnd = total
            } else {
                // Look for the `>` starting right after
                // `closeAngle`. If we find one, include up
                // to and through it; otherwise stop at the
                // end of the body.
                let gtSearch = NSRange(
                    location: closeAngle + 1,
                    length: total - (closeAngle + 1)
                )
                let gt = ns.range(of: ">", range: gtSearch).location
                if gt != NSNotFound {
                    consumedEnd = Int(gt) + 1
                } else {
                    consumedEnd = total
                }
            }
            consumed.append((openAngle, consumedEnd - openAngle))
            // Extract the value between `>` and the close `<`.
            let valueStart = nameEnd + 1
            let valueEnd = closeAngle == NSNotFound ? total : Int(closeAngle)
            guard valueStart <= valueEnd else {
                tagSearch = consumedEnd
                continue
            }
            let rawValue = ns.substring(
                with: NSRange(location: valueStart, length: valueEnd - valueStart)
            )
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data),
               !(parsed is NSNull) {
                fromTags[tagName] = parsed
            } else {
                fromTags[tagName] = trimmed
            }
            tagSearch = consumedEnd
        }
        if !fromTags.isEmpty {
            return (fromTags, consumed)
        }
        // 2. Key-value shape. Each `key=value` entry
        //    contributes a value. Entries can appear on their
        //    own line (`id=…\ninput={…}`) or on a single line
        //    (`id=… input={…}` — MiniMax M3's newest emit
        //    when it stuffs the structured form inside
        //    `[tool_call: read_file id=… input={…}]`). The
        //    pattern is `key=value` where the value is a
        //    balanced JSON object / array or a run of
        //    non-whitespace characters. Line ranges are
        //    recorded so the caller can strip them from the
        //    cleaned text.
        var fromKeyValue: [String: Any] = [:]
        var kvConsumed: [(Int, Int)] = []
        var lineStart = 0
        // Cached regex for the key-value pattern. Values:
        // 1. `{...}` — balanced JSON object (no nested braces,
        //    which is fine for the parameter payloads the
        //    model emits).
        // 2. `[...]` — balanced JSON array, same constraint.
        // 3. `\S+` — a single non-whitespace token (the call
        //    id, a bare string, etc.).
        let kvPattern = #"([A-Za-z_][A-Za-z0-9_]*)=(\{(?:[^{}]|\{[^{}]*\})*\}|\[(?:[^\[\]]|\[[^\[\]]*\])*\]|\S+)"#
        let kvRegex = try? NSRegularExpression(
            pattern: kvPattern,
            options: []
        )
        while lineStart <= total {
            // Find the next newline in the body.
            let searchRange = NSRange(
                location: lineStart,
                length: max(0, total - lineStart)
            )
            let nl = ns.range(of: "\n", range: searchRange).location
            let newlineIdx: Int = nl == NSNotFound ? total : nl
            let lineRange = NSRange(
                location: lineStart,
                length: max(0, newlineIdx - lineStart)
            )
            if lineRange.length > 0 {
                let line = ns.substring(with: lineRange)
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedLine.isEmpty {
                    // Collect every `key=value` match on the
                    // line. If we find at least one, the whole
                    // line is consumed (caller strips it from
                    // the visible text).
                    var matchedAny = false
                    if let regex = kvRegex {
                        let matchRange = NSRange(
                            location: 0,
                            length: (trimmedLine as NSString).length
                        )
                        regex.enumerateMatches(
                            in: trimmedLine,
                            options: [],
                            range: matchRange
                        ) { match, _, _ in
                            guard let match = match,
                                  match.numberOfRanges == 3
                            else { return }
                            let keyNSRange = match.range(at: 1)
                            let valueNSRange = match.range(at: 2)
                            guard let keyRange = Range(keyNSRange, in: trimmedLine),
                                  let valueRange = Range(valueNSRange, in: trimmedLine)
                            else { return }
                            let key = String(trimmedLine[keyRange])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let value = String(trimmedLine[valueRange])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !key.isEmpty, key != "id", key != "name" else { return }
                            matchedAny = true
                            if let data = value.data(using: .utf8),
                               let parsed = try? JSONSerialization.jsonObject(with: data),
                               !(parsed is NSNull)
                            {
                                if key == "input", let dict = parsed as? [String: Any] {
                                    for (k, v) in dict { fromKeyValue[k] = v }
                                } else {
                                    fromKeyValue[key] = parsed
                                }
                            } else {
                                fromKeyValue[key] = value
                            }
                        }
                    }
                    if matchedAny {
                        kvConsumed.append((lineStart, newlineIdx - lineStart))
                    }
                }
            }
            if newlineIdx >= total { break }
            lineStart = newlineIdx + 1
        }
        return (fromKeyValue, kvConsumed)
    }

    /// Parse provider-text tool-call markup out of an assistant
    /// message body. Covers the MiniMax M3 format:
    ///
    ///     `<think>…</think> [tool_call: run_shell]<command>ls /code</command>`
    ///
    /// and the newer log-style emit:
    ///
    ///     `[tool: ?] <command>\n--- stdout ---\n<output>\n--- stderr ---\n<error>`
    ///
    /// For the structured marker (`[tool_call: name]`) the
    /// body uses `<param>value</param>` blocks (each block's
    /// value is treated as a string unless it parses as JSON,
    /// in which case the parsed value is used — lets
    /// `write_file` and friends pass nested objects). For the
    /// log-style marker (`[tool: <name>]`), the body is the
    /// model's imagined run log: only the first line is real
    /// (the command), the `--- stdout ---` / `--- stderr ---`
    /// sections are fabrication. We extract the command and
    /// drop the rest from the visible text — the e2b sandbox
    /// produces the authoritative result on dispatch. Returns
    /// the visible content with thinking + tool-call markup
    /// stripped so the user never sees raw provider XML.
    nonisolated static func parseProviderTextToolCalls(_ raw: String) -> ProviderTextResult {
        var text = raw

        // 0. Normalise the "stuffed" key-value marker shape
        //    that MiniMax M3 started emitting. The model
        //    sometimes puts the structured payload INSIDE
        //    the brackets instead of after them:
        //      `[tool_call: read_file id=… input={…}]`
        //    The rest of the parser (and the existing tests
        //    / runner) expects the body AFTER the closing
        //    `]`, so we rewrite this shape into the older
        //      `[tool_call: read_file] id=… input={…}`
        //    form before scanning. Doing the rewrite up
        //    front (and outside the marker scan loop) keeps
        //    the scanner simple and means every later pass
        //    sees a single canonical shape.
        if let newShapeRegex = try? NSRegularExpression(
            pattern: #"\[(tool_call|tool):\s*([A-Za-z0-9_?]+)\s+([^\]]+)\]"#,
            options: [.caseInsensitive]
        ) {
            let nsText = text as NSString
            let allMatches = newShapeRegex.matches(
                in: text,
                range: NSRange(location: 0, length: nsText.length)
            )
            // Apply in reverse so each rewrite doesn't shift
            // the ranges of the remaining matches.
            for match in allMatches.reversed() {
                guard match.numberOfRanges == 4,
                      let fullRange = Range(match.range(at: 0), in: text),
                      let prefixRange = Range(match.range(at: 1), in: text),
                      let nameRange = Range(match.range(at: 2), in: text),
                      let bodyRange = Range(match.range(at: 3), in: text)
                else { continue }
                let prefix = String(text[prefixRange]).lowercased()
                let name = String(text[nameRange])
                let body = String(text[bodyRange])
                let rewritten = "[\(prefix): \(name)] \(body)"
                text.replaceSubrange(fullRange, with: rewritten)
            }
        }

        // 1. Pull thinking out. Same tag names as the chat
        //    composer's ThinkingExtractor so the runner /
        //    view can reuse the existing pipeline. We loop
        //    over every paired `<think>…</think>` block (the
        //    model sometimes emits several in a row) and then
        //    sweep stray open/close tags and unclosed open
        //    tags so `</think>` / `<think>` never leak into
        //    the visible bubble.
        var thinkingParts: [String] = []
        let pairedThink = try? NSRegularExpression(
            pattern: #"<(think|thinking|reasoning|reflection|thought|analysis)\b[^>]*>[\s\S]*?</\1>"#,
            options: [.caseInsensitive]
        )
        if let regex = pairedThink {
            let full = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: full)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let innerRange = Range(match.range(at: 0), in: text)
                else { continue }
                let inner = text[innerRange]
                if let openEnd = inner.range(of: ">"),
                   let closeStart = inner.range(of: "</", options: .backwards) {
                    let body = inner[openEnd.upperBound..<closeStart.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { thinkingParts.append(body) }
                }
            }
            text = regex.stringByReplacingMatches(
                in: text, options: [], range: full, withTemplate: ""
            )
        }
        // Unclosed `<think>` (still streaming) — capture the
        // body after it and drop the tag so it doesn't leak.
        let openOnlyThink = try? NSRegularExpression(
            pattern: #"<(think|thinking|reasoning|reflection|thought|analysis)\b[^>]*>[\s\S]*$"#,
            options: [.caseInsensitive]
        )
        if let regex = openOnlyThink {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let innerRange = Range(match.range(at: 0), in: text),
               let openEnd = text[innerRange].range(of: ">") {
                let body = text[innerRange][openEnd.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { thinkingParts.append(body) }
                text = String(text[..<innerRange.lowerBound])
            }
        }
        // Stray open/close tags left after the primary
        // extraction. The chat composer's ThinkingExtractor
        // does the same sweep so any pair the model emits
        // without a matching opener is still scrubbed.
        let residualThink = try? NSRegularExpression(
            pattern: #"</?(think|thinking|reasoning|reflection|thought|analysis)\b[^>]*>"#,
            options: [.caseInsensitive]
        )
        if let regex = residualThink {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(
                in: text, options: [], range: range, withTemplate: ""
            )
        }
        let thinking: String? = thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n\n")

        // 2. Extract tool calls. Each block starts with a
        //    marker and ends at the next marker or end of
        //    text. Two marker shapes are supported; both come
        //    from MiniMax M3 at different temperatures:
        //    - `[tool_call: <name>]` — tag / key-value body.
        //    - `[tool: <name>]` — log-style body where the
        //      model emits `<command>\n--- stdout ---\n<output>\n--- stderr ---\n<error>`.
        // Use Swift's String APIs for the marker scan so we
        // stay in character-space (no NSRange / UTF-16
        // round-tripping). The marker is the literal
        // `[<prefix>: <name>]` opener, and the block body
        // runs from the close `]` to the next opener or end
        // of text.
        struct Hit {
            let markerStart: String.Index
            let markerEnd: String.Index
            let blockEnd: String.Index
            let name: String
            let inputObject: [String: Any]
        }
        var hits: [Hit] = []
        // Collect marker positions first.
        var markerPositions: [(start: String.Index, end: String.Index, name: String, isLogStyle: Bool)] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            guard let openBracket = text[searchStart...].firstIndex(of: "[") else { break }
            let rest = text[openBracket...]
            // Look for the closing `]` within the same line-ish window
            // (MiniMax emits `[tool_call: name]` on a single line).
            guard let closeBracket = rest.firstIndex(of: "]") else { break }
            // Verify the content between `[` and `]` is one of
            // the accepted markers (`tool_call: <name>` for
            // the structured shape, `tool: <name>` for the
            // log-style shape). The pre-processor at the top
            // of this function has already rewritten the
            // "stuffed" shape (`[tool_call: read_file id=…
            // input={…}]`) into the old shape, so the
            // scanner only sees canonical markers here.
            let inside = rest[rest.index(after: openBracket)..<closeBracket]
            let insideLower = inside.lowercased()
            var kind: String? = nil
            var rawName: String = ""
            if insideLower.hasPrefix("tool_call:") {
                kind = "tool_call"
                rawName = String(inside.dropFirst("tool_call:".count))
            } else if insideLower.hasPrefix("tool:") {
                kind = "tool"
                rawName = String(inside.dropFirst("tool:".count))
            }
            if let kind {
                let nameTrimmed = rawName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // MiniMax M3 sometimes writes `[tool: ?]`
                // (literal question mark) when the model
                // hasn't filled in a name — every emit of
                // that shape is a `run_shell` in practice, so
                // normalise to keep the rest of the pipeline
                // simple.
                let normalisedName = (nameTrimmed == "?" || nameTrimmed.isEmpty)
                    ? "run_shell"
                    : nameTrimmed
                if normalisedName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                    markerPositions.append((
                        openBracket,
                        rest.index(after: closeBracket),
                        normalisedName,
                        kind == "tool"
                    ))
                }
            }
            searchStart = text.index(after: openBracket)
        }
        // Build per-marker blocks AND the cleaned text in a
        // single pass. We collect the kept segments of the
        // original `text` (everything outside the tool-call
        // markup) and concatenate them at the end — no
        // in-place mutation, so every `String.Index` from
        // `text` stays valid for the whole loop. This also
        // lets us handle the trailing-newline case cleanly
        // (the previous in-place `replaceSubrange` was
        // tripping String.IndexValidation when the block
        // ended exactly at `text.endIndex`).
        var keptSegments: [String] = []
        var lastAppendEnd: String.Index = text.startIndex
        for (i, marker) in markerPositions.enumerated() {
            let nextStart: String.Index
            if i + 1 < markerPositions.count {
                nextStart = markerPositions[i + 1].start
            } else {
                nextStart = text.endIndex
            }
            var blockEnd = nextStart
            // For the LAST log-style marker, the body (from
            // `marker.end` to `text.endIndex`) includes any
            // trailing prose the model wrote after the log
            // section. We must not consume that prose — it's
            // user-visible content. The log section ends at
            // the first blank line (`\n\n`), which is how
            // MiniMax separates one log block from the next
            // and from any closing prose. Intermediate
            // log-style blocks already stop at the next
            // marker, so this only fires for the last one.
            if marker.isLogStyle && i + 1 == markerPositions.count {
                let bodyRange = marker.end..<text.endIndex
                if let blankLineLower = text.range(of: "\n\n", range: bodyRange) {
                    blockEnd = blankLineLower.lowerBound
                }
            }
            guard marker.end <= blockEnd else { continue }
            // Keep the text between the last appended end and
            // the start of this marker.
            if lastAppendEnd < marker.start {
                keptSegments.append(String(text[lastAppendEnd..<marker.start]))
            }
            let block = String(text[marker.end..<blockEnd])
            // Two body shapes:
            // - `[tool: <name>]` is the log-style emit
            //   (`<command>\n--- stdout ---\n…`); the model
            //   is fabricating both the call AND the result
            //   so we extract just the first line and drop
            //   the rest from the visible text.
            // - `[tool_call: <name>]` is the structured emit
            //   (`<param>value</param>` or `id=…\ninput={…}`).
            let (inputObject, consumedRanges): ([String: Any], [(Int, Int)])
            if marker.isLogStyle {
                (inputObject, consumedRanges) = Self.parseLogStyleToolCallBody(block)
            } else {
                (inputObject, consumedRanges) = Self.parseToolCallBody(block)
            }
            // Build the kept portion of the block by
            // skipping the consumed character ranges. The
            // parser hands back `(start, length)` character
            // offsets (NSString-based) so the rebuild uses
            // its own indices, not String.Index.
            let blockNS = block as NSString
            let trimmedBlock: String
            if consumedRanges.isEmpty {
                trimmedBlock = block
            } else {
                let sorted = consumedRanges.sorted { $0.0 < $1.0 }
                var kept = ""
                var cursor = 0
                for (start, length) in sorted {
                    if cursor < start {
                        let r = NSRange(location: cursor, length: start - cursor)
                        kept += blockNS.substring(with: r)
                    }
                    cursor = start + length
                }
                if cursor < block.count {
                    let r = NSRange(location: cursor, length: block.count - cursor)
                    kept += blockNS.substring(with: r)
                }
                trimmedBlock = kept
            }
            // If the block itself is non-empty after stripping,
            // we still drop it (it was the model emitting the
            // tool call). The leading marker has already been
            // excluded by the `lastAppendEnd` slice above; the
            // block's content is the model's tool-call
            // markup which we don't want in the visible text.
            // Just track the call and move on.
            hits.append(Hit(
                markerStart: marker.start,
                markerEnd: marker.end,
                blockEnd: blockEnd,
                name: marker.name,
                inputObject: inputObject
            ))
            // The kept portion (if any) is non-markup text
            // that fell between the open tag and the close
            // tag — MiniMax sometimes puts prose there. Keep
            // it so the user sees the model's preface.
            if !trimmedBlock.isEmpty {
                keptSegments.append(trimmedBlock)
            }
            lastAppendEnd = blockEnd
        }
        // Tail after the last marker.
        if lastAppendEnd < text.endIndex {
            keptSegments.append(String(text[lastAppendEnd..<text.endIndex]))
        }
        // Assemble + tidy. `+` between String literals allocates
        // a new buffer; the kept segments are short so this is
        // cheap.
        var cleaned = keptSegments.joined()
        cleaned = cleaned
            .replacingOccurrences(
                of: #"[ \t]{2,}"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\n[ \t]+"#,
                with: "\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Build the calls list (in forward order, with our
        // own id scheme — the parser's `id=…` line is
        // metadata, not our call id).
        var calls: [ProviderTextCall] = []
        for (i, hit) in hits.enumerated() {
            let argumentsData = (try? JSONSerialization.data(
                withJSONObject: hit.inputObject,
                options: [.sortedKeys]
            )) ?? Data("{}".utf8)
            let argumentsJSON = String(data: argumentsData, encoding: .utf8) ?? "{}"
            let id = "tc_text_\(i)_\(UUID().uuidString.prefix(8))"
            calls.append(ProviderTextCall(
                id: id,
                name: hit.name,
                argumentsJSON: argumentsJSON
            ))
        }

        return ProviderTextResult(
            thinking: thinking,
            content: cleaned,
            toolCalls: calls
        )
    }

    /// Build the Chat Completions request body. Messages are
    /// flattened: `AgentLLMMessage` is a (role, content) pair;
    /// for OpenAI we emit the matching message shape. Tool
    /// calls inside the transcript (the runner appends them as
    /// `assistant` text in v1) are passed through as plain text
    /// for now — a follow-up can render them as proper
    /// `tool_calls` history entries.
    private static func buildBody(
        system: String,
        messages: [AgentLLMMessage],
        tools: [AgentLLMTool],
        modelID: String,
        maxTokens: Int,
    ) -> [String: Any] {
        var wireMessages: [[String: Any]] = [
            ["role": "system", "content": system]
        ]
        for m in messages {
            switch m.role {
            case .user, .assistant, .system:
                wireMessages.append(["role": m.role.rawValue, "content": m.content])
            }
        }
        var body: [String: Any] = [
            "model": modelID,
            "messages": wireMessages,
            "max_tokens": maxTokens,
            "stream": true,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": schemaToDict(tool.inputSchema),
                    ],
                ]
            }
        }
        return body
    }

    /// Recursively flatten our `AgentLLMInputSchema` (a Codable
    /// type) into `[String: Any]` for JSONSerialization.
    private static func schemaToDict(_ schema: AgentLLMInputSchema) -> [String: Any] {
        var d: [String: Any] = ["type": schema.type]
        if !schema.properties.isEmpty {
            d["properties"] = schema.properties.mapValues { p in
                var v: [String: Any] = ["type": p.type]
                if let d = p.description { v["description"] = d }
                return v
            }
        }
        if let req = schema.required { d["required"] = req }
        return d
    }

    /// Post the streaming chat-completions request. Returns
    /// the `URLSession.AsyncBytes` for line-by-line SSE parsing.
    private func post(body: [String: Any]) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("anyprov-code", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await session.bytes(for: req)
    }

    /// Parse a single OpenAI streaming chunk. Yields events via
    /// the `continuation` and returns `.stop` when the server
    /// signals `finish_reason: stop` so the caller can break.
    private static func parseChunk(
        _ json: String,
        acc: inout [Int: ToolCallAcc],
        continuation: AsyncThrowingStream<AgentLLMEvent, Error>.Continuation,
    ) -> Bool {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any]
        else { return false }
        // Text content.
        if let content = delta["content"] as? String, !content.isEmpty {
            continuation.yield(.textDelta(text: content))
        }
        // Tool calls. OpenAI streams them as `delta.tool_calls`
        // — an array of {index, id?, function: {name?, arguments?}}.
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                let index = tc["index"] as? Int ?? 0
                if var existing = acc[index] {
                    if let id = tc["id"] as? String { existing.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String { existing.name = name }
                        if let args = fn["arguments"] as? String {
                            existing.arguments.append(args)
                        }
                    }
                    acc[index] = existing
                } else {
                    var entry = ToolCallAcc()
                    if let id = tc["id"] as? String { entry.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String { entry.name = name }
                        if let args = fn["arguments"] as? String { entry.arguments = args }
                    }
                    acc[index] = entry
                    // Emit a toolCallStart as soon as we have
                    // something to send.
                    if !entry.id.isEmpty && !entry.name.isEmpty {
                        continuation.yield(.toolCallStart(
                            id: entry.id,
                            name: entry.name,
                            input: .init(raw: .object([:]))
                        ))
                    }
                }
            }
        }
        // finish_reason on this choice tells us the response
        // is over. For tool_calls, also emit a toolCallInputDelta
        // + toolCallEnd per accumulated tool so the runner can
        // dispatch. For stop, we return true to break the loop.
        if let reason = first["finish_reason"] as? String, !reason.isEmpty {
            if reason == "stop" || reason == "length" || reason == "end_turn" {
                return true
            }
            if reason == "tool_calls" {
                for (_, entry) in acc {
                    if !entry.id.isEmpty, !entry.name.isEmpty {
                        continuation.yield(.toolCallInputDelta(
                            id: entry.id, partialJSON: entry.arguments
                        ))
                        let parsed = parseJSON(entry.arguments)
                        continuation.yield(.toolCallStart(
                            id: entry.id, name: entry.name, input: parsed
                        ))
                        continuation.yield(.toolCallEnd(id: entry.id))
                    }
                }
            }
        }
        // Usage block (only sent on the final chunk for some
        // providers). We forward it if present.
        if let usage = parsed["usage"] as? [String: Any] {
            let input = usage["prompt_tokens"] as? Int ?? 0
            let output = usage["completion_tokens"] as? Int ?? 0
            if input > 0 || output > 0 {
                continuation.yield(.usage(inputTokens: input, outputTokens: output))
            }
        }
        return false
    }

    private static func parseJSON(_ s: String) -> AgentLLMInput {
        let raw = s.data(using: .utf8).flatMap { data in
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } ?? [:]
        return .init(raw: dictionaryToAnyJSON(raw))
    }

    private static func dictionaryToAnyJSON(_ d: [String: Any]) -> AnyJSON {
        var out: [String: AnyJSON] = [:]
        for (k, v) in d {
            out[k] = anyToAnyJSON(v)
        }
        return .object(out)
    }

    private static func anyToAnyJSON(_ v: Any) -> AnyJSON {
        if v is NSNull { return .nullValue }
        if let b = v as? Bool { return .bool(b) }
        if let i = v as? Int { return .int(i) }
        if let d = v as? Double { return .double(d) }
        if let s = v as? String { return .string(s) }
        if let a = v as? [Any] { return .array(a.map(anyToAnyJSON)) }
        if let o = v as? [String: Any] { return dictionaryToAnyJSON(o) }
        return .nullValue
    }
}

/// HTTP / transport errors raised by the OpenAI-compatible client.
/// The shared `AgentLLMError.unsupportedProvider` lives in
/// `AgentLLM.swift`.
enum OpenAICompatibleError: Error, LocalizedError {
    case httpStatus(Int, String)
    case transport(String)
    case decoding(String)
    /// The upstream opened the stream but never produced a
    /// terminating chunk in time. Usually means the chosen
    /// model doesn't actually support OpenAI's tool-calling
    /// wire format (chat-only models) — the runner surfaces
    /// this so the user can swap models.
    case streamTimeout(elapsed: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .httpStatus(code, body):
            let snippet = body.isEmpty ? "" : " — \(body.prefix(160))"
            return "LLM HTTP \(code)\(snippet)"
        case let .transport(msg): return "LLM transport: \(msg)"
        case let .decoding(msg): return "LLM decode: \(msg)"
        case let .streamTimeout(elapsed):
            return "LLM stream timed out after \(Int(elapsed))s. The model accepted the request but never sent a complete response — usually means it doesn't support the tool-calling format the E2B agent uses. Try a different model."
        }
    }
}
