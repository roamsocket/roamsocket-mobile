/**
 * Deterministic mock provider for tests and offline smoke runs. It reacts to
 * the latest user/tool message so the agent loop can be exercised end-to-end
 * without any API key or network access.
 *
 * Behavior: on the first user turn it calls `write_file` to create NOTES.md,
 * then on seeing the tool result it emits a closing message and stops.
 */
import type { ProviderAdapter, CompletionRequest, ProviderEvent } from "./types.js";

export const mockAdapter: ProviderAdapter = {
  id: "anthropic",
  async *stream(req: CompletionRequest): AsyncGenerator<ProviderEvent> {
    const last = req.messages[req.messages.length - 1];
    const alreadyWrote = req.messages.some(
      (m) => m.role === "tool" && m.name === "write_file",
    );

    if (last?.role === "tool" || alreadyWrote) {
      yield { kind: "text", text: "Done — created NOTES.md with a short note." };
      yield { kind: "done", stopReason: "end_turn" };
      return;
    }

    yield { kind: "text", text: "I'll add a NOTES.md file to the repository." };
    yield {
      kind: "tool_call",
      call: {
        id: "mock-call-1",
        name: "write_file",
        input: { path: "NOTES.md", content: "# Notes\n\nCreated by the mock agent.\n" },
      },
    };
    yield { kind: "done", stopReason: "tool_use" };
  },
};
