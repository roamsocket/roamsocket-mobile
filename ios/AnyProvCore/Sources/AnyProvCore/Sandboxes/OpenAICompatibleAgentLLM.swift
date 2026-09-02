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

    /// Parse provider-text tool-call markup out of an assistant
    /// message body. Covers the MiniMax M3 format:
    ///
    ///     `<think>…</think> [tool_call: run_shell]<command>ls /code</command>`
    ///
    /// Each `[tool_call: name]` is followed by one or more
    /// `<param>value</param>` blocks; the body of each block is
    /// treated as a string unless it parses as JSON, in which
    /// case the parsed value is used (lets `write_file` and
    /// friends pass nested objects). Returns the visible
    /// content with thinking + tool-call markup stripped so
    /// the user never sees raw provider XML.
    nonisolated static func parseProviderTextToolCalls(_ raw: String) -> ProviderTextResult {
        var text = raw

        // 1. Pull thinking out. Same tag names as the chat
        //    composer's ThinkingExtractor so the runner /
        //    view can reuse the existing pipeline.
        var thinking: String?
        if let thinkRange = text.range(
            of: #"<(think|thinking|reasoning|reflection|thought|analysis)\b[^>]*>[\s\S]*?</\1>"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let inner = text[thinkRange]
            // Strip the outer tags.
            if let openEnd = inner.range(of: ">"),
               let closeStart = inner.range(of: "</", options: .backwards) {
                let body = inner[openEnd.upperBound..<closeStart.lowerBound]
                thinking = body.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            text.replaceSubrange(thinkRange, with: "")
        }

        // 2. Extract tool calls. Each block starts with
        //    `[tool_call: <name>]` and ends at the next
        //    `[tool_call:` marker or end of text. Parameter
        //    pairs are `<param>value</param>` tags inside the
        //    block.
        // Use Swift's String APIs for the marker scan so we
        // stay in character-space (no NSRange / UTF-16
        // round-tripping). The marker is the literal
        // `[tool_call: <name>]` opener, and the block body
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
        var markerPositions: [(start: String.Index, end: String.Index, name: String)] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            guard let openBracket = text[searchStart...].firstIndex(of: "[") else { break }
            let rest = text[openBracket...]
            // Look for the closing `]` within the same line-ish window
            // (MiniMax emits `[tool_call: name]` on a single line).
            guard let closeBracket = rest.firstIndex(of: "]") else { break }
            // Verify the content between `[` and `]` is `tool_call: <name>`.
            let inside = rest[rest.index(after: openBracket)..<closeBracket]
            if inside.lowercased().hasPrefix("tool_call:") {
                let nameStart = rest.index(after: openBracket)
                let nameTrimmed = inside
                    .dropFirst("tool_call:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let name = String(nameTrimmed)
                if !name.isEmpty,
                   name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                    markerPositions.append((openBracket, rest.index(after: closeBracket), name))
                }
            }
            searchStart = text.index(after: openBracket)
        }
        // Build per-marker blocks.
        for (i, marker) in markerPositions.enumerated() {
            let nextStart: String.Index
            if i + 1 < markerPositions.count {
                nextStart = markerPositions[i + 1].start
            } else {
                nextStart = text.endIndex
            }
            let blockEnd = nextStart
            guard marker.end <= blockEnd else { continue }
            let block = String(text[marker.end..<blockEnd])
            // Extract `<param>value</param>` pairs.
            var inputObject: [String: Any] = [:]
            var tagSearch = block.startIndex
            while tagSearch < block.endIndex {
                guard let openAngle = block[tagSearch...].firstIndex(of: "<") else { break }
                let afterOpen = block.index(after: openAngle)
                // Tag name: letters / digits / underscore / dash,
                // terminated by whitespace or `>`.
                var nameEnd = afterOpen
                while nameEnd < block.endIndex,
                      let c = block[nameEnd].unicodeScalars.first,
                      (CharacterSet.letters.contains(c) ||
                       CharacterSet.decimalDigits.contains(c) ||
                       c == "_" || c == "-") {
                    nameEnd = block.index(after: nameEnd)
                }
                guard nameEnd > afterOpen,
                      block[nameEnd] == ">",
                      let closeAngle = block[nameEnd...].firstIndex(of: "<"),
                      block[closeAngle...].hasPrefix("</")
                else {
                    // No more parseable tag on this line — bail.
                    break
                }
                let tagName = String(block[afterOpen..<nameEnd])
                // Match `</tagName>` exactly so we don't accidentally
                // close on a similarly-named inner tag.
                let expectedCloseStart = closeAngle
                let closeTagNameStart = block.index(after: expectedCloseStart)
                guard closeTagNameStart < block.endIndex,
                      block[closeTagNameStart] == "/"
                else {
                    // Malformed close tag — skip.
                    tagSearch = block.index(after: openAngle)
                    continue
                }
                let closeTagNameAfterSlash = block.index(after: closeTagNameStart)
                var closeNameEnd = closeTagNameAfterSlash
                while closeNameEnd < block.endIndex,
                      let c = block[closeNameEnd].unicodeScalars.first,
                      (CharacterSet.letters.contains(c) ||
                       CharacterSet.decimalDigits.contains(c) ||
                       c == "_" || c == "-") {
                    closeNameEnd = block.index(after: closeNameEnd)
                }
                guard closeNameEnd < block.endIndex,
                      block[closeNameEnd] == ">"
                else {
                    // Malformed close tag — skip.
                    tagSearch = block.index(after: openAngle)
                    continue
                }
                let closeTagName = String(block[closeTagNameAfterSlash..<closeNameEnd])
                guard closeTagName == tagName else {
                    // Mismatched close tag — skip this open.
                    tagSearch = block.index(after: openAngle)
                    continue
                }
                let valueStart = block.index(after: nameEnd)
                let valueEnd = expectedCloseStart
                let raw = String(block[valueStart..<valueEnd])
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let data = trimmed.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data),
                   !(parsed is NSNull) {
                    inputObject[tagName] = parsed
                } else {
                    inputObject[tagName] = trimmed
                }
                // Continue scanning after the close tag.
                tagSearch = block.index(after: closeNameEnd)
            }
            hits.append(Hit(
                markerStart: marker.start,
                markerEnd: marker.end,
                blockEnd: blockEnd,
                name: marker.name,
                inputObject: inputObject
            ))
        }
        // Mutate `text` in reverse (so earlier offsets stay
        // valid) and assemble the result in forward order.
        var calls: [ProviderTextCall] = []
        for (i, hit) in hits.enumerated().reversed() {
            let argumentsData = (try? JSONSerialization.data(
                withJSONObject: hit.inputObject,
                options: [.sortedKeys]
            )) ?? Data("{}".utf8)
            let argumentsJSON = String(data: argumentsData, encoding: .utf8) ?? "{}"
            let id = "tc_text_\(i)_\(UUID().uuidString.prefix(8))"
            calls.insert(ProviderTextCall(
                id: id,
                name: hit.name,
                argumentsJSON: argumentsJSON
            ), at: 0)
            // Strip this block (including the leading marker)
            // from `text` so the user never sees the markup.
            text.replaceSubrange(
                hit.markerStart..<hit.blockEnd,
                with: ""
            )
        }

        // Tidy up: collapse runs of whitespace left by
        // removal, then trim.
        let cleaned = text
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
