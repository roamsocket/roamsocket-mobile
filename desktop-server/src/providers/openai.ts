/**
 * OpenAI-compatible Chat Completions adapter (/v1/chat/completions).
 * Reused for OpenAI, Groq, OpenRouter, xAI, and Mistral by varying baseUrl.
 * Non-streaming for robustness; emits the assistant text as a single event.
 */
import type { ProviderId } from "../protocol.js";
import type { ProviderAdapter, CompletionRequest, ProviderEvent, NormalizedMessage } from "./types.js";

const BASE_URLS: Record<string, string> = {
  openai: "https://api.openai.com/v1",
  groq: "https://api.groq.com/openai/v1",
  openrouter: "https://openrouter.ai/api/v1",
  xai: "https://api.x.ai/v1",
  mistral: "https://api.mistral.ai/v1",
};

function toOpenAIMessages(system: string, messages: NormalizedMessage[]): unknown[] {
  const out: unknown[] = [{ role: "system", content: system }];
  for (const m of messages) {
    if (m.role === "user") {
      out.push({ role: "user", content: m.text });
    } else if (m.role === "assistant") {
      out.push({
        role: "assistant",
        content: m.text || null,
        tool_calls: m.toolCalls.length
          ? m.toolCalls.map((c) => ({
              id: c.id,
              type: "function",
              function: { name: c.name, arguments: JSON.stringify(c.input) },
            }))
          : undefined,
      });
    } else {
      out.push({ role: "tool", tool_call_id: m.toolCallId, content: m.output });
    }
  }
  return out;
}

export function makeOpenAICompatibleAdapter(id: ProviderId): ProviderAdapter {
  const baseUrl = BASE_URLS[id] ?? BASE_URLS.openai!;
  return {
    id,
    async *stream(req: CompletionRequest, signal?: AbortSignal): AsyncGenerator<ProviderEvent> {
      const body = {
        model: req.model,
        messages: toOpenAIMessages(req.system, req.messages),
        tools: req.tools.map((t) => ({
          type: "function",
          function: { name: t.name, description: t.description, parameters: t.inputSchema },
        })),
      };
      const res = await fetch(`${baseUrl}/chat/completions`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${req.apiKey}`,
        },
        body: JSON.stringify(body),
        signal,
      });
      if (!res.ok) {
        const errText = await res.text().catch(() => res.statusText);
        throw new Error(`${id} API error ${res.status}: ${errText}`);
      }
      const json: any = await res.json();
      const choice = json.choices?.[0];
      const message = choice?.message ?? {};
      if (message.content) {
        yield { kind: "text", text: String(message.content) };
      }
      for (const call of message.tool_calls ?? []) {
        let input: Record<string, unknown> = {};
        try {
          input = JSON.parse(call.function?.arguments || "{}");
        } catch {
          input = {};
        }
        yield { kind: "tool_call", call: { id: call.id, name: call.function?.name, input } };
      }
      yield { kind: "done", stopReason: choice?.finish_reason ?? "stop" };
    },
  };
}
