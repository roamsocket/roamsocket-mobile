/** Anthropic Messages API adapter with streaming tool-use (/v1/messages, SSE). */
import type { ProviderId } from '../protocol.js';
import type {
  ProviderAdapter,
  CompletionRequest,
  ProviderEvent,
  NormalizedMessage,
} from './types.js';

const DEFAULT_BASE = 'https://api.anthropic.com/v1';
const VERSION = '2023-06-01';

function stripTrailingSlash(url: string): string {
  return url.replace(/\/+$/, '');
}

/** Convert normalized messages into Anthropic's content-block format. */
function toAnthropicMessages(messages: NormalizedMessage[]): unknown[] {
  const out: unknown[] = [];
  for (const m of messages) {
    if (m.role === 'user') {
      out.push({ role: 'user', content: [{ type: 'text', text: m.text }] });
    } else if (m.role === 'assistant') {
      const content: unknown[] = [];
      if (m.text) content.push({ type: 'text', text: m.text });
      for (const c of m.toolCalls) {
        content.push({ type: 'tool_use', id: c.id, name: c.name, input: c.input });
      }
      out.push({ role: 'assistant', content });
    } else {
      // tool result -> a user message carrying a tool_result block
      out.push({
        role: 'user',
        content: [
          {
            type: 'tool_result',
            tool_use_id: m.toolCallId,
            content: m.output,
            is_error: !m.ok,
          },
        ],
      });
    }
  }
  return out;
}

function effortToTokens(effort: string): number {
  return effort === 'low' ? 4096 : effort === 'medium' ? 8192 : 16384;
}

export function makeAnthropicAdapter(
  id: ProviderId = 'anthropic',
  baseUrlOverride?: string
): ProviderAdapter {
  const baseUrl = stripTrailingSlash(baseUrlOverride || DEFAULT_BASE);
  const endpoint = `${baseUrl}/messages`;
  return {
    id,
    async *stream(req: CompletionRequest, signal?: AbortSignal): AsyncGenerator<ProviderEvent> {
      const body = {
        model: req.model,
        max_tokens: effortToTokens(req.effort),
        system: req.system,
        messages: toAnthropicMessages(req.messages),
        tools: req.tools.map((t) => ({
          name: t.name,
          description: t.description,
          input_schema: t.inputSchema,
        })),
        stream: true,
      };

      const res = await fetch(endpoint, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-api-key': req.apiKey,
          'anthropic-version': VERSION,
        },
        body: JSON.stringify(body),
        signal,
      });
      if (!res.ok || !res.body) {
        const errText = await res.text().catch(() => res.statusText);
        throw new Error(`Anthropic API error ${res.status} (${endpoint}): ${errText}`);
      }

      // Track in-progress tool_use blocks by index to assemble streamed JSON.
      const toolBlocks = new Map<number, { id: string; name: string; json: string }>();
      let stopReason = 'end_turn';

      for await (const event of parseSSE(res.body)) {
        const data = event.data;
        if (!data || data === '[DONE]') continue;
        let json: any;
        try {
          json = JSON.parse(data);
        } catch {
          continue;
        }
        switch (json.type) {
          case 'content_block_start':
            if (json.content_block?.type === 'tool_use') {
              toolBlocks.set(json.index, {
                id: json.content_block.id,
                name: json.content_block.name,
                json: '',
              });
            }
            break;
          case 'content_block_delta':
            if (json.delta?.type === 'text_delta') {
              yield { kind: 'text', text: json.delta.text };
            } else if (json.delta?.type === 'input_json_delta') {
              const block = toolBlocks.get(json.index);
              if (block) block.json += json.delta.partial_json ?? '';
            }
            break;
          case 'content_block_stop': {
            const block = toolBlocks.get(json.index);
            if (block) {
              let input: Record<string, unknown> = {};
              try {
                input = block.json ? JSON.parse(block.json) : {};
              } catch {
                input = {};
              }
              yield { kind: 'tool_call', call: { id: block.id, name: block.name, input } };
              toolBlocks.delete(json.index);
            }
            break;
          }
          case 'message_delta':
            if (json.delta?.stop_reason) stopReason = json.delta.stop_reason;
            break;
          default:
            break;
        }
      }
      yield { kind: 'done', stopReason };
    },
  };
}

/** Default Anthropic cloud adapter. */
export const anthropicAdapter: ProviderAdapter = makeAnthropicAdapter('anthropic');

/** Minimal SSE line parser over a fetch ReadableStream. */
async function* parseSSE(
  body: ReadableStream<Uint8Array>
): AsyncGenerator<{ event?: string; data: string }> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let idx: number;
    while ((idx = buffer.indexOf('\n\n')) !== -1) {
      const chunk = buffer.slice(0, idx);
      buffer = buffer.slice(idx + 2);
      let event: string | undefined;
      let data = '';
      for (const line of chunk.split('\n')) {
        if (line.startsWith('event:')) event = line.slice(6).trim();
        else if (line.startsWith('data:')) data += line.slice(5).trim();
      }
      if (data) yield { event, data };
    }
  }
}
