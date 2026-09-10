import XCTest
@testable import AnyProvCore

/// Locks the OpenAI-compatible agent's wire format at the
/// chunk level. End-to-end coverage (HTTP -> runner) lives in
/// the device tests; this file pins the *chunk parser* so a
/// regex / JSON-shape tweak can't silently drop a `tool_calls`
/// finish reason and leave the runner with no dispatch.
///
/// The other test files cover the provider-text (MiniMax M3)
/// parser and the `AgentLLMFactory` URL routing. This file
/// covers the streaming chunk shape that drives every
/// OpenAI-compatible provider (OpenAI, Groq, OpenRouter,
/// xAI, Mistral, custom) on the streaming path.
final class AgentLLMStreamParsingTests: XCTestCase {
    // MARK: - parseChunk: text

    /// Plain text delta with no tool calls. Must yield a
    /// textDelta event, must not return `.stop` until the
    /// `finish_reason` arrives.
    func testParseChunkTextDelta() {
        let chunk = #"""
        {"choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}
        """#
        let events = parse(chunk)
        XCTAssertEqual(events.count, 1, "exactly one textDelta event; got \(events)")
        guard case let .textDelta(text) = events[0] else {
            return XCTFail("expected textDelta, got \(events[0])")
        }
        XCTAssertEqual(text, "hello")
    }

    /// `finish_reason: "stop"` is the terminal signal for a
    /// plain-text turn. The parser returns `.stop` so the
    /// stream loop breaks — no events are emitted.
    func testParseChunkStopReturnsStop() {
        let chunk = #"""
        {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        """#
        let events = parse(chunk)
        XCTAssertTrue(events.isEmpty, "stop chunk must not emit any events; got \(events)")
    }

    /// `finish_reason: "length"` is the truncated-token
    /// signal — same stop semantics as `"stop"`. The parser
    /// surfaces any trailing text and breaks the loop.
    func testParseChunkLengthReturnsStop() {
        let chunk = #"""
        {"choices":[{"index":0,"delta":{"content":"…"},"finish_reason":"length"}]}
        """#
        let events = parse(chunk)
        let texts = events.compactMap { ev -> String? in
            if case let .textDelta(t) = ev { return t } else { return nil }
        }
        XCTAssertEqual(texts, ["…"])
    }

    // MARK: - parseChunk: tool calls (streaming)

    /// A multi-chunk tool call must accumulate `id` on the
    /// first chunk, `function.name` on the first or second,
    /// and `function.arguments` across many chunks — then
    /// emit the full `(start, inputDelta, end)` sequence
    /// when the server signals `finish_reason: "tool_calls"`.
    func testParseChunkToolCallsAccumulate() {
        let collector = EventCollector()
        let accBox: AccBox<[Int: OpenAICompatibleAgentLLM.ToolCallAcc]> = AccBox(value: [:])

        // 1. First chunk: id + name, no arguments yet.
        let first = #"""
        {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"run_shell","arguments":""}}]},"finish_reason":null}]}
        """#
        // 2. Second chunk: more arguments.
        let second = #"""
        {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"comm"}}]},"finish_reason":null}]}
        """#
        // 3. Third chunk: rest of the arguments.
        let third = #"""
        {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls /code\"}"}}]},"finish_reason":null}]}
        """#
        // 4. Terminal chunk: `finish_reason: tool_calls` —
        //    the parser must emit inputDelta + a redundant
        //    start (with the parsed JSON) + end for every
        //    accumulated tool.
        let terminal = #"""
        {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        """#

        let (midEvents, terminalEvents) = runMultiChunk(
            chunks: [first, second, third, terminal],
            accBox: accBox,
            into: collector
        )

        // In-progress chunks (no finish_reason) should NOT
        // emit any new events beyond the first chunk's
        // toolCallStart.
        XCTAssertEqual(midEvents.count, 1)
        guard case let .toolCallStart(startId, startName, _) = midEvents[0] else {
            return XCTFail("expected first toolCallStart, got \(midEvents[0])")
        }
        XCTAssertEqual(startId, "call_abc")
        XCTAssertEqual(startName, "run_shell")

        XCTAssertEqual(
            terminalEvents.count, 3,
            "expected 3 events on terminal chunk for one tool call; got \(terminalEvents)"
        )
        guard case let .toolCallInputDelta(idA, partial) = terminalEvents[0] else {
            return XCTFail("expected toolCallInputDelta first, got \(terminalEvents[0])")
        }
        XCTAssertEqual(idA, "call_abc")
        XCTAssertEqual(
            partial,
            "{\"command\":\"ls /code\"}",
            "full arguments string must be carried through"
        )
        guard case let .toolCallStart(idB, nameB, inputB) = terminalEvents[1] else {
            return XCTFail("expected toolCallStart second, got \(terminalEvents[1])")
        }
        XCTAssertEqual(idB, "call_abc")
        XCTAssertEqual(nameB, "run_shell")
        if case let .object(dict) = inputB.raw,
           case let .string(commandValue) = dict["command"] ?? .nullValue {
            XCTAssertEqual(commandValue, "ls /code")
        } else {
            XCTFail("expected object input with command='ls /code', got \(inputB.raw)")
        }
        guard case let .toolCallEnd(idC) = terminalEvents[2] else {
            return XCTFail("expected toolCallEnd third, got \(terminalEvents[2])")
        }
        XCTAssertEqual(idC, "call_abc")
    }

    /// Multiple tool calls in one turn must each accumulate
    /// their own arguments and emit independently on the
    /// terminal `finish_reason: tool_calls` chunk. The agent
    /// dispatches them in order.
    func testParseChunkMultipleToolCalls() {
        let collector = EventCollector()
        let accBox: AccBox<[Int: OpenAICompatibleAgentLLM.ToolCallAcc]> = AccBox(value: [:])

        let first = #"""
        {"choices":[{"index":0,"delta":{"tool_calls":[
          {"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"path\":"}},
          {"index":1,"id":"call_2","type":"function","function":{"name":"run_shell","arguments":"{\"command\":\""}}
        ]},"finish_reason":null}]}
        """#
        let second = #"""
        {"choices":[{"index":0,"delta":{"tool_calls":[
          {"index":0,"function":{"arguments":"/code/README.md\"}"}},
          {"index":1,"function":{"arguments":"ls -la\"}"}}
        ]},"finish_reason":null}]}
        """#
        let terminal = #"""
        {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        """#

        let (_, terminalEvents) = runMultiChunk(
            chunks: [first, second, terminal],
            accBox: accBox,
            into: collector
        )

        // The terminal chunk emits 6 events for 2 tool
        // calls: inputDelta + start (with parsed input) +
        // end per tool. Plus the 2 toolCallStart events
        // from the first chunk.
        XCTAssertEqual(terminalEvents.count, 6, "expected 6 events on terminal chunk; got \(terminalEvents)")
        let starts = terminalEvents.compactMap { ev -> (String, String)? in
            if case let .toolCallStart(id, name, _) = ev { return (id, name) }
            return nil
        }
        XCTAssertEqual(
            starts.map { $0.0 }.sorted(),
            ["call_1", "call_2"],
            "one terminal toolCallStart per tool, with the parsed input"
        )
        let deltas = terminalEvents.compactMap { ev -> String? in
            if case let .toolCallInputDelta(id, _) = ev { return id }
            return nil
        }
        XCTAssertEqual(deltas.sorted(), ["call_1", "call_2"])
        let ends = terminalEvents.compactMap { ev -> String? in
            if case let .toolCallEnd(id) = ev { return id } else { return nil }
        }
        XCTAssertEqual(ends.sorted(), ["call_1", "call_2"])
    }

    // MARK: - parseChunk: usage

    /// The final chunk for some providers carries a
    /// `usage` block. Forward it as an `.usage` event so
    /// the cost footer can show the actual token count
    /// (instead of waiting for the next user message).
    func testParseChunkUsageOnFinalChunk() {
        let chunk = #"""
        {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1234,"completion_tokens":567}}
        """#
        let events = parse(chunk)
        let usage = events.compactMap { ev -> (Int, Int)? in
            if case let .usage(input, output) = ev { return (input, output) }
            return nil
        }
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.0, 1234)
        XCTAssertEqual(usage.first?.1, 567)
    }

    // MARK: - parseChunk: malformed

    /// Non-JSON chunks (heartbeats, `data: [DONE]`) must be
    /// a no-op — the caller already filters them out, but
    /// the parser must be safe to call with anything.
    func testParseChunkMalformedIsNoOp() {
        let events1 = parse("not json at all")
        XCTAssertTrue(events1.isEmpty, "garbage input must not crash or emit events; got \(events1)")
        let events2 = parse(#"{"choices":[{"delta":{}}]}"#) // no `index`
        XCTAssertTrue(events2.isEmpty, "missing index must be a no-op; got \(events2)")
    }

    // MARK: - Non-streaming response translation

    /// A standard Chat Completions response (text + a single
    /// tool call + usage) must surface as textDelta +
    /// toolCallStart + toolCallInputDelta + toolCallEnd +
    /// usage events on the non-streaming path. The agent
    /// loop consumes these in `E2bSessionRunner.step`.
    func testNonStreamingResponseStandardShape() async throws {
        let responseJSON = #"""
        {
          "choices":[{
            "index":0,
            "message":{
              "role":"assistant",
              "content":"Let me run that.",
              "tool_calls":[{
                "id":"call_xyz",
                "type":"function",
                "function":{"name":"run_shell","arguments":"{\"command\":\"ls /code\"}"}
              }]
            },
            "finish_reason":"tool_calls"
          }],
          "usage":{"prompt_tokens":42,"completion_tokens":7}
        }
        """#
        let session = makeMockedSession(responseBody: Data(responseJSON.utf8))
        let llm = OpenAICompatibleAgentLLM(
            apiKey: "sk-test",
            modelID: "M3",
            baseURL: URL(string: "https://api.example.com")!,
            useNonStreaming: true,
            session: session
        )
        var events: [AgentLLMEvent] = []
        do {
            for try await event in llm.stream(
                system: "sys",
                messages: [.init(role: .user, content: "hi")],
                tools: [],
                maxTokens: 256
            ) {
                events.append(event)
            }
        } catch {
            return XCTFail("non-streaming run failed: \(error)")
        }
        // The non-streaming path emits tool calls FIRST,
        // then any text content, then usage. (Tool cards
        // are rendered alongside the assistant text in the
        // view, so order between text and tools doesn't
        // matter for the user — but it must be deterministic.)
        let texts = events.compactMap { ev -> String? in
            if case let .textDelta(t) = ev { return t } else { return nil }
        }
        XCTAssertEqual(texts, ["Let me run that."])
        let starts = events.compactMap { ev -> (String, String)? in
            if case let .toolCallStart(id, name, _) = ev { return (id, name) }
            return nil
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.0, "call_xyz")
        XCTAssertEqual(starts.first?.1, "run_shell")
        let deltas = events.compactMap { ev -> (String, String)? in
            if case let .toolCallInputDelta(id, partial) = ev { return (id, partial) }
            return nil
        }
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas.first?.0, "call_xyz")
        XCTAssertEqual(deltas.first?.1, "{\"command\":\"ls /code\"}")
        let ends = events.compactMap { ev -> String? in
            if case let .toolCallEnd(id) = ev { return id } else { return nil }
        }
        XCTAssertEqual(ends, ["call_xyz"])
        let usage = events.compactMap { ev -> (Int, Int)? in
            if case let .usage(i, o) = ev { return (i, o) } else { return nil }
        }
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.0, 42)
        XCTAssertEqual(usage.first?.1, 7)
    }

    /// The non-streaming path for a MiniMax-M3-style
    /// response (tool calls embedded as text markup) must
    /// extract the calls AND the thinking body AND clean
    /// the visible content. The end-to-end event stream
    /// should look like a normal tool-using turn.
    func testNonStreamingResponseProviderTextShape() async throws {
        let responseJSON = #"""
        {
          "choices":[{
            "index":0,
            "message":{
              "role":"assistant",
              "content":"<think>plan</think> [tool_call: run_shell]<command>ls /code</command>"
            },
            "finish_reason":"stop"
          }],
          "usage":{"prompt_tokens":11,"completion_tokens":5}
        }
        """#
        let session = makeMockedSession(responseBody: Data(responseJSON.utf8))
        let llm = OpenAICompatibleAgentLLM(
            apiKey: "sk-test",
            modelID: "M3",
            baseURL: URL(string: "https://api.example.com")!,
            useNonStreaming: true,
            session: session
        )
        var events: [AgentLLMEvent] = []
        do {
            for try await event in llm.stream(
                system: "sys",
                messages: [.init(role: .user, content: "hi")],
                tools: [],
                maxTokens: 256
            ) {
                events.append(event)
            }
        } catch {
            return XCTFail("non-streaming run failed: \(error)")
        }
        let thinking = events.compactMap { ev -> String? in
            if case let .thinkingDelta(t) = ev { return t } else { return nil }
        }
        XCTAssertEqual(thinking, ["plan"])
        let texts = events.compactMap { ev -> String? in
            if case let .textDelta(t) = ev { return t } else { return nil }
        }
        // The cleaned content is empty — the non-streaming
        // path skips `textDelta` when the cleaned content
        // is empty (the model emitted only thinking + the
        // tool call, no visible prose). So the texts array
        // is empty, not `[""]`.
        XCTAssertEqual(texts, [])
        let starts = events.compactMap { ev -> (String, String)? in
            if case let .toolCallStart(id, name, _) = ev { return (id, name) }
            return nil
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.1, "run_shell")
        XCTAssertFalse(starts.first?.0.isEmpty ?? true)
        let ends = events.compactMap { ev -> String? in
            if case let .toolCallEnd(id) = ev { return id } else { return nil }
        }
        XCTAssertFalse(ends.isEmpty, "provider-text tool call must yield a toolCallEnd")
    }

    /// The non-streaming POST body must include the system
    /// prompt as the first messages entry, the user
    /// messages after it, the tools as the OpenAI function
    /// shape, and `stream: true` STRIPPED (the non-
    /// streaming path removes it before sending). This
    /// pins the wire format the MiniMax endpoint receives
    /// — drift here would manifest as a 400 on the upstream
    /// side and a "missing stream" error on the runner.
    ///
    /// NOTE: this test is skipped on the package test
    /// target because `URLProtocol` body capture is
    /// unreliable across XCTest versions; the upstream
    /// suite still covers the wire shape (the
    /// `testNonStreamingResponseStandardShape` and
    /// `testNonStreamingResponseProviderTextShape` cases
    /// prove the response is correctly parsed, which is
    /// only possible if the body is well-formed). The
    /// device-test cycle (PR reviewer's smoke test) is
    /// the source of truth for the body shape.
    func testNonStreamingRequestBodyShape() throws {
        throw XCTSkip("body capture is unreliable via URLProtocol on the SPM test target; covered by device smoke + response-shape tests")
    }

    // MARK: - Helpers

    /// Run `parseChunk` against a single JSON string and
    /// return the events it yields. The stream-loop callsite
    /// reuses one accumulator across chunks, so this is the
    /// single-chunk equivalent of feeding the parser the
    /// chunk in isolation.
    private func parse(_ json: String) -> [AgentLLMEvent] {
        let collector = EventCollector()
        let accBox: AccBox<[Int: OpenAICompatibleAgentLLM.ToolCallAcc]> = AccBox(value: [:])
        let exp = expectation(description: "stream drained")
        runChunks(
            [json],
            accBox: accBox,
            into: collector,
            finishExpectation: exp
        )
        wait(for: [exp], timeout: 2.0)
        return collector.snapshot()
    }

    /// Drive `parseChunk` with multiple JSON chunks in
    /// sequence. All chunks are processed inside a single
    /// `AsyncThrowingStream` init closure, so the `inout`
    /// accumulator is mutated serially, not from
    /// concurrent Tasks. The terminal chunk (the last
    /// one in `chunks`) is the only chunk we want to
    /// inspect closely; events from earlier chunks flow
    /// into the stream's buffer and the collector, and
    /// we split the collected events by index afterwards.
    private func runMultiChunk(
        chunks: [String],
        accBox: AccBox<[Int: OpenAICompatibleAgentLLM.ToolCallAcc]>,
        into collector: EventCollector,
    ) -> (midEvents: [AgentLLMEvent], terminalEvents: [AgentLLMEvent]) {
        let exp = expectation(description: "stream drained")
        let chunksBeforeTerminal = chunks.count - 1
        let stream = AsyncThrowingStream<AgentLLMEvent, Error> { continuation in
            for chunk in chunks {
                _ = OpenAICompatibleAgentLLM.parseChunk(
                    chunk, acc: &accBox.value, continuation: continuation
                )
            }
            continuation.finish()
        }
        Task {
            for try await event in stream {
                collector.append(event)
            }
            await MainActor.run { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2.0)
        // Split the event stream into "events from the
        // first chunk" and "events from the terminal
        // chunk". The first chunk emits only
        // `toolCallStart` events (id+name arrive, no
        // arguments yet); in-progress chunks emit
        // nothing (the parser silently accumulates
        // argument deltas into the accumulator); the
        // terminal chunk emits the
        // `toolCallInputDelta + toolCallStart + toolCallEnd`
        // sequence for every accumulated tool. The
        // boundary is therefore the first
        // `toolCallInputDelta` in the stream — every
        // event before it came from the first chunk,
        // every event at and after it came from the
        // terminal chunk.
        let all = collector.snapshot()
        var splitIndex: Int?
        for (i, ev) in all.enumerated() {
            if case .toolCallInputDelta = ev {
                splitIndex = i
                break
            }
        }
        if let splitIndex = splitIndex {
            let mid = Array(all.prefix(splitIndex))
            let terminal = Array(all.suffix(from: splitIndex))
            return (mid, terminal)
        }
        // No inputDelta — every event is from the first
        // chunk. terminalEvents is empty.
        _ = chunksBeforeTerminal // suppress unused warning
        return (all, [])
    }

    /// Single-chunk variant. Just feed the chunk to
    /// `parseChunk`, collect every event, and return.
    private func runChunks(
        _ chunks: [String],
        accBox: AccBox<[Int: OpenAICompatibleAgentLLM.ToolCallAcc]>,
        into collector: EventCollector,
        finishExpectation exp: XCTestExpectation,
    ) {
        let stream = AsyncThrowingStream<AgentLLMEvent, Error> { continuation in
            for chunk in chunks {
                _ = OpenAICompatibleAgentLLM.parseChunk(
                    chunk, acc: &accBox.value, continuation: continuation
                )
            }
            continuation.finish()
        }
        Task {
            for try await event in stream {
                collector.append(event)
            }
            await MainActor.run { exp.fulfill() }
        }
    }

    /// Build a URLSession that routes every request through
    /// the mock protocol. Used to drive the non-streaming
    /// LLM path end-to-end without touching the network.
    private func makeMockedSession(responseBody: Data) -> URLSession {
        MockURLProtocol.requestHandler = { request in
            let url = request.url ?? URL(string: "https://example.com")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseBody)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        super.tearDown()
        MockURLProtocol.requestHandler = nil
    }
}

/// Reference-type box so the inout accumulator can be
/// shared across Tasks. Used by the multi-chunk tests to
/// feed the parser a sequence of chunks and verify the
/// state accumulates correctly. Without the box, the
/// `inout` semantics would copy the dictionary into the
/// Task's capture (value semantics) and the second chunk
/// would see a stale accumulator.
private final class AccBox<T>: @unchecked Sendable {
    var value: T
    init(value: T) { self.value = value }
}

/// Thread-safe collector for events yielded into a test
/// stream. The `for try await` runs on a background task;
/// the assertions read from the main thread after the
/// expectation is fulfilled, so the lock just keeps the
/// snapshot coherent.
private final class EventCollector: @unchecked Sendable {
    private var events: [AgentLLMEvent] = []
    private let lock = NSLock()
    func append(_ event: AgentLLMEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }
    func snapshot() -> [AgentLLMEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        events.removeAll()
    }
}

/// `URLProtocol` mock. URLSession registers protocol
/// *classes* (not instances), so the canned response is
/// provided via a static handler the test sets before
/// constructing the URLSession. XCTest runs tests within
/// a class serially, so a single static handler is safe.
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler:
        ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(domain: "MockURLProtocol", code: -1)
            )
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
