import Foundation

/// `AgentLLM` implementation that talks to Anthropic's
/// Messages API via the existing `AnthropicClient`. Translates
/// the Anthropic `Message.Content` + `StreamEvent` into the
/// provider-agnostic `AgentLLMEvent`.
public actor AnthropicAgentLLM: AgentLLM {
    let anthropic: AnthropicClient
    let maxTokens: Int

    public init(
        apiKey: String,
        modelID: String = "claude-sonnet-4-5",
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        maxTokens: Int = 4096,
    ) {
        self.anthropic = AnthropicClient(apiKey: apiKey, model: modelID, baseURL: baseURL)
        self.maxTokens = maxTokens
    }

    public nonisolated func stream(
        system: String,
        messages: [AgentLLMMessage],
        tools: [AgentLLMTool],
        maxTokens: Int,
    ) -> AsyncThrowingStream<AgentLLMEvent, Error> {
        // Translate the provider-agnostic messages to Anthropic's
        // Message type. Each AgentLLMMessage has a single text
        // content; tool outputs / notices are folded into the
        // assistant or user role as plain text.
        let anthropicMessages = messages.map(Self.toAnthropicMessage)
        let anthropicTools = tools.map(Self.toAnthropicTool)
        let cap = maxTokens

        // Drain AnthropicClient.stream and translate events as
        // they arrive. The stream is cancelled if the consumer
        // cancels the AsyncThrowingStream.
        return AsyncThrowingStream<AgentLLMEvent, Error> { continuation in
            let task = Task {
                do {
                    var inToolUse: [Int: (id: String, name: String, partialJSON: String)] = [:]
                    for try await event in await anthropic.stream(
                        system: system,
                        messages: anthropicMessages,
                        tools: anthropicTools,
                        maxTokens: cap
                    ) {
                        if Task.isCancelled { break }
                        switch event {
                        case .messageStart, .ping, .contentBlockStop:
                            continue
                        case let .contentBlockStart(index, type):
                            if type == "tool_use" {
                                inToolUse[index] = (id: "tool_\(index)", name: "", partialJSON: "")
                            }
                        case let .textDelta(_, text):
                            continuation.yield(.textDelta(text: text))
                        case let .inputJsonDelta(index, partial):
                            if var entry = inToolUse[index] {
                                entry.partialJSON.append(partial)
                                inToolUse[index] = entry
                            }
                        case let .messageDelta(_, usage):
                            if let usage {
                                continuation.yield(.usage(
                                    inputTokens: usage.inputTokens,
                                    outputTokens: usage.outputTokens
                                ))
                            }
                        case .messageStop:
                            // Emit a toolCallEnd + toolCallStart per
                            // accumulated tool-use block so the
                            // runner can dispatch.
                            for (_, entry) in inToolUse where !entry.name.isEmpty {
                                continuation.yield(.toolCallEnd(id: entry.id))
                            }
                            break
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

    private static func toAnthropicMessage(_ m: AgentLLMMessage) -> AnthropicClient.Message {
        switch m.role {
        case .user: return .init(role: "user", content: [.text(m.content)])
        case .assistant: return .init(role: "assistant", content: [.text(m.content)])
        case .system: return .init(role: "user", content: [.text("[system] " + m.content)])
        }
    }

    private static func toAnthropicTool(_ t: AgentLLMTool) -> AnthropicClient.Tool {
        // Translate the JSON schema into the AnyJSON value the
        // Anthropic client expects.
        let schemaDict: [String: AnyJSON] = [
            "type": .string(t.inputSchema.type),
            "properties": .object(t.inputSchema.properties.mapValues { prop in
                var d: [String: AnyJSON] = ["type": .string(prop.type)]
                if let desc = prop.description { d["description"] = .string(desc) }
                return .object(d)
            }),
        ]
        var anySchema: [String: AnyJSON] = schemaDict
        if let required = t.inputSchema.required {
            anySchema["required"] = .array(required.map { .string($0) })
        }
        return .init(
            name: t.name,
            description: t.description,
            inputSchema: .object(anySchema)
        )
    }
}
