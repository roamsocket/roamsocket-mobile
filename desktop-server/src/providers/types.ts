/**
 * Provider adapters used by the server-side agent loop. Each provider maps a
 * normalized conversation to its own API and yields a normalized event stream
 * so the agent loop stays provider-agnostic.
 */
import type { ProviderId } from "../protocol.js";
import type { Tool } from "../tools/index.js";

export interface NormalizedToolCall {
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export type NormalizedMessage =
  | { role: "user"; text: string }
  | { role: "assistant"; text: string; toolCalls: NormalizedToolCall[] }
  | { role: "tool"; toolCallId: string; name: string; output: string; ok: boolean };

export interface CompletionRequest {
  model: string;
  apiKey: string;
  system: string;
  messages: NormalizedMessage[];
  tools: Tool[];
  effort: "low" | "medium" | "high";
}

export type ProviderEvent =
  | { kind: "text"; text: string }
  | { kind: "tool_call"; call: NormalizedToolCall }
  | { kind: "done"; stopReason: string };

export interface ProviderAdapter {
  id: ProviderId;
  /** Yield a normalized event stream for one assistant turn. */
  stream(req: CompletionRequest, signal?: AbortSignal): AsyncGenerator<ProviderEvent>;
}
