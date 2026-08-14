/**
 * Desktop Metal / MLX adapter for the coding agent loop.
 *
 * mlx-lm does not expose native tool calling, so tools are described in the
 * system prompt and the model is asked to emit zero or more
 * `<tool_call>{"name","arguments"}</tool_call>` blocks. Text outside those
 * blocks is streamed as assistant prose.
 */
import { randomUUID } from 'node:crypto';
import type {
  ProviderAdapter,
  CompletionRequest,
  ProviderEvent,
  NormalizedMessage,
} from './types.js';
import { metalGenerate } from '../metal/runtime.js';
import { METAL_PROVIDER_ID } from '../metal/catalog.js';

const TOOL_CALL_RE = /<tool_call>\s*([\s\S]*?)\s*<\/tool_call>/gi;

function buildToolInstructions(req: CompletionRequest): string {
  const toolLines = req.tools.map((t) => {
    const schema = JSON.stringify(t.inputSchema ?? { type: 'object', properties: {} });
    return `- ${t.name}: ${t.description}\n  JSON parameters schema: ${schema}`;
  });
  return [
    'You are running as a desktop coding agent with tools.',
    'When you need a tool, emit one or more blocks exactly like:',
    '<tool_call>{"name":"tool_name","arguments":{...}}</tool_call>',
    'Do not wrap tool JSON in markdown fences. You may include short prose before tool calls.',
    'When you are finished and need no tools, reply with normal assistant text only (no tool_call tags).',
    '',
    'Available tools:',
    ...toolLines,
  ].join('\n');
}

function toMetalMessages(
  system: string,
  messages: NormalizedMessage[]
): Array<{ role: 'user' | 'assistant' | 'system'; content: string }> {
  const out: Array<{ role: 'user' | 'assistant' | 'system'; content: string }> = [
    { role: 'system', content: system },
  ];
  for (const m of messages) {
    if (m.role === 'user') {
      out.push({ role: 'user', content: m.text });
    } else if (m.role === 'assistant') {
      let content = m.text ?? '';
      if (m.toolCalls.length > 0) {
        const blocks = m.toolCalls
          .map(
            (c) => `<tool_call>${JSON.stringify({ name: c.name, arguments: c.input })}</tool_call>`
          )
          .join('\n');
        content = content ? `${content}\n${blocks}` : blocks;
      }
      out.push({ role: 'assistant', content });
    } else {
      out.push({
        role: 'user',
        content: `Tool result for ${m.name} (${m.ok ? 'ok' : 'error'}):\n${m.output}`,
      });
    }
  }
  return out;
}

function parseToolCalls(text: string): {
  prose: string;
  calls: Array<{ id: string; name: string; input: Record<string, unknown> }>;
} {
  const calls: Array<{ id: string; name: string; input: Record<string, unknown> }> = [];
  let prose = text;
  const matches = [...text.matchAll(TOOL_CALL_RE)];
  for (const match of matches) {
    const raw = (match[1] ?? '').trim();
    try {
      const parsed = JSON.parse(raw) as { name?: string; arguments?: unknown; input?: unknown };
      const name = typeof parsed.name === 'string' ? parsed.name : '';
      if (!name) continue;
      let input: Record<string, unknown> = {};
      const args = parsed.arguments ?? parsed.input ?? {};
      if (args && typeof args === 'object' && !Array.isArray(args)) {
        input = args as Record<string, unknown>;
      } else if (typeof args === 'string') {
        try {
          input = JSON.parse(args) as Record<string, unknown>;
        } catch {
          input = { value: args };
        }
      }
      calls.push({ id: randomUUID(), name, input });
    } catch {
      // Ignore malformed tool_call blocks; keep them in prose for the user.
    }
  }
  if (matches.length > 0) {
    prose = text.replace(TOOL_CALL_RE, '').trim();
  }
  return { prose, calls };
}

function maxTokensForEffort(effort: CompletionRequest['effort']): number {
  switch (effort) {
    case 'low':
      return 512;
    case 'medium':
      return 1024;
    case 'high':
    default:
      return 2048;
  }
}

/** True for wire provider ids that mean desktop Metal / MLX. */
export function isMetalProviderId(provider: string): boolean {
  return (
    provider === METAL_PROVIDER_ID ||
    provider === 'local-metal' ||
    provider === 'metal' ||
    provider === 'local'
  );
}

export const metalAgentAdapter: ProviderAdapter = {
  id: METAL_PROVIDER_ID,
  async *stream(req: CompletionRequest, signal?: AbortSignal): AsyncGenerator<ProviderEvent> {
    if (signal?.aborted) {
      yield { kind: 'done', stopReason: 'aborted' };
      return;
    }
    const system = `${req.system}\n\n${buildToolInstructions(req)}`;
    const messages = toMetalMessages(system, req.messages);

    // Bridge metalGenerate's onProgress callback into the async generator via
    // a tiny queue so loading/generating status streams to the agent loop.
    const queue: ProviderEvent[] = [];
    let resolvers: Array<() => void> = [];
    let producerDone = false;
    const push = (ev: ProviderEvent) => {
      queue.push(ev);
      for (const r of resolvers) r();
      resolvers = [];
    };

    const run = (async () => {
      try {
        const result = await metalGenerate(
          {
            hubID: req.model,
            messages,
            maxTokens: maxTokensForEffort(req.effort),
          },
          (p) => {
            push({
              kind: 'model_status',
              status: p.phase,
              hubID: p.hubID,
              message: p.message,
            });
          }
        );
        if (signal?.aborted) {
          push({ kind: 'done', stopReason: 'aborted' });
          return;
        }
        const { prose, calls } = parseToolCalls(result.text);
        if (prose) {
          push({ kind: 'text', text: prose });
        }
        for (const call of calls) {
          push({ kind: 'tool_call', call });
        }
        push({ kind: 'model_status', status: 'done' });
        push({
          kind: 'done',
          stopReason: calls.length > 0 ? 'tool_use' : 'end_turn',
        });
      } catch (err) {
        push({ kind: 'model_status', status: 'done' });
        throw err;
      } finally {
        producerDone = true;
        for (const r of resolvers) r();
        resolvers = [];
      }
    })();

    while (true) {
      const ev = queue.shift();
      if (ev) {
        yield ev;
        if (ev.kind === 'done') return;
        continue;
      }
      if (producerDone) {
        await run;
        return;
      }
      await new Promise<void>((resolve) => {
        resolvers.push(resolve);
      });
    }
  },
};
