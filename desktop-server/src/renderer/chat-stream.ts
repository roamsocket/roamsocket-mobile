/**
 * BYOK chat streaming from the renderer (Anthropic SSE + OpenAI-compatible).
 * Metal models are handled via main-process IPC (not this module).
 *
 * Custom / proxy hosts pass `baseUrl` + `apiStyle` so requests never fall
 * through to built-in cloud defaults.
 */
import {
  chatRequestTarget,
  type CustomApiStyle,
  type ResolvedEndpoint,
} from "../client/custom-providers.js";

export interface ChatTurn {
  role: "user" | "assistant" | "system";
  content: string;
}

export interface StreamChatOptions {
  provider: string;
  model: string;
  apiKey: string;
  messages: ChatTurn[];
  signal?: AbortSignal;
  onDelta: (text: string) => void;
  /** Override host for custom / proxy endpoints (includes version segment). */
  baseUrl?: string;
  /** Wire format when baseUrl is set (or custom: provider). Defaults to openai. */
  apiStyle?: CustomApiStyle;
  /** Live web search via the provider-native API (OpenRouter `web` plugin). */
  webSearch?: boolean;
}

export async function streamChat(opts: StreamChatOptions): Promise<string> {
  if (opts.provider === "localMetal") {
    throw new Error("Metal chat must use the desktop Metal runtime (IPC), not HTTP stream.");
  }

  const endpoint: ResolvedEndpoint | null =
    opts.baseUrl?.trim()
      ? {
          baseUrl: opts.baseUrl.replace(/\/+$/, ""),
          apiStyle: opts.apiStyle === "anthropic" ? "anthropic" : "openai",
        }
      : null;

  const target = chatRequestTarget(opts.provider, endpoint);
  if (target.style === "error") {
    throw new Error(target.message);
  }
  if (target.style === "metal") {
    throw new Error("Metal chat must use the desktop Metal runtime (IPC), not HTTP stream.");
  }
  if (target.style === "google") {
    return streamGoogle(opts);
  }
  if (target.style === "anthropic") {
    return streamAnthropic(opts, target.url);
  }
  return streamOpenAICompatible(opts, target.url);
}

async function streamAnthropic(opts: StreamChatOptions, url: string): Promise<string> {
  const system = opts.messages.filter((m) => m.role === "system").map((m) => m.content).join("\n");
  const messages = opts.messages
    .filter((m) => m.role === "user" || m.role === "assistant")
    .map((m) => ({
      role: m.role,
      content: [{ type: "text", text: m.content }],
    }));

  const res = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": opts.apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: opts.model,
      max_tokens: 8192,
      system: system || undefined,
      messages,
      stream: true,
    }),
    signal: opts.signal,
  });
  if (!res.ok || !res.body) {
    const err = await res.text().catch(() => res.statusText);
    throw new Error(`Anthropic ${res.status}: ${err.slice(0, 400)}`);
  }

  let full = "";
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    const parts = buf.split("\n");
    buf = parts.pop() ?? "";
    for (const line of parts) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("data:")) continue;
      const data = trimmed.slice(5).trim();
      if (!data || data === "[DONE]") continue;
      try {
        const json = JSON.parse(data) as {
          type?: string;
          delta?: { type?: string; text?: string };
        };
        if (json.type === "content_block_delta" && json.delta?.type === "text_delta" && json.delta.text) {
          full += json.delta.text;
          opts.onDelta(json.delta.text);
        }
      } catch {
        // skip
      }
    }
  }
  return full;
}

async function streamOpenAICompatible(opts: StreamChatOptions, url: string): Promise<string> {
  // OpenRouter runs web search server-side via its `web` plugin.
  const nativeWebSearch = opts.provider === "openrouter" && opts.webSearch === true;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${opts.apiKey || "none"}`,
    },
    body: JSON.stringify({
      model: opts.model,
      messages: opts.messages.map((m) => ({ role: m.role, content: m.content })),
      stream: true,
      ...(nativeWebSearch ? { plugins: [{ id: "web", max_results: 5 }] } : {}),
    }),
    signal: opts.signal,
  });
  if (!res.ok || !res.body) {
    const err = await res.text().catch(() => res.statusText);
    throw new Error(`${opts.provider} ${res.status}: ${err.slice(0, 400)}`);
  }

  let full = "";
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    const parts = buf.split("\n");
    buf = parts.pop() ?? "";
    for (const line of parts) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("data:")) continue;
      const data = trimmed.slice(5).trim();
      if (!data || data === "[DONE]") continue;
      try {
        const json = JSON.parse(data) as {
          choices?: Array<{ delta?: { content?: string } }>;
        };
        const delta = json.choices?.[0]?.delta?.content;
        if (delta) {
          full += delta;
          opts.onDelta(delta);
        }
      } catch {
        // skip
      }
    }
  }
  // Some providers return non-stream JSON if stream unsupported — handle once
  if (!full && buf.trim()) {
    try {
      const json = JSON.parse(buf) as { choices?: Array<{ message?: { content?: string } }> };
      const text = json.choices?.[0]?.message?.content ?? "";
      if (text) {
        opts.onDelta(text);
        return text;
      }
    } catch {
      // ignore
    }
  }
  return full;
}

async function streamGoogle(opts: StreamChatOptions): Promise<string> {
  // Non-streaming generateContent for reliability
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(opts.model)}:generateContent?key=${encodeURIComponent(opts.apiKey)}`;
  const contents = opts.messages
    .filter((m) => m.role === "user" || m.role === "assistant")
    .map((m) => ({
      role: m.role === "assistant" ? "model" : "user",
      parts: [{ text: m.content }],
    }));
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ contents }),
    signal: opts.signal,
  });
  if (!res.ok) {
    const err = await res.text().catch(() => res.statusText);
    throw new Error(`Google ${res.status}: ${err.slice(0, 400)}`);
  }
  const json = (await res.json()) as {
    candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
  };
  const text =
    json.candidates?.[0]?.content?.parts?.map((p) => p.text ?? "").join("") ?? "";
  if (text) opts.onDelta(text);
  return text;
}
