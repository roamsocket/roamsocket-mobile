/**
 * List real models for a keyed cloud provider (renderer / unit-testable).
 * Returns [] when the key is missing (built-ins), the provider is unsupported,
 * or the API fails. Never invents static “default” model ids.
 *
 * Custom / proxy endpoints pass `baseUrl` (+ optional `apiStyle`) so listing
 * hits the user host rather than a built-in cloud default.
 */
import type { CustomApiStyle } from "./custom-providers.js";

export interface ListedCloudModel {
  id: string;
  displayName: string;
}

const OPENAI_BASE: Record<string, string> = {
  openai: "https://api.openai.com/v1",
  groq: "https://api.groq.com/openai/v1",
  openrouter: "https://openrouter.ai/api/v1",
  xai: "https://api.x.ai/v1",
  mistral: "https://api.mistral.ai/v1",
  minimax: "https://api.minimax.io/v1",
};

export type FetchLike = (
  input: string,
  init?: { headers?: Record<string, string>; signal?: AbortSignal },
) => Promise<{ ok: boolean; status: number; json: () => Promise<unknown> }>;

export interface ListCloudModelsOptions {
  /** Override host (custom providers / proxies). Includes version segment. */
  baseUrl?: string;
  /** Wire format when using baseUrl. Defaults to openai. */
  apiStyle?: CustomApiStyle;
  fetchImpl?: FetchLike;
  signal?: AbortSignal;
}

/**
 * Fetch models for a BYOK provider. Empty when listing fails.
 * Built-ins still require a non-empty API key. Custom endpoints with `baseUrl`
 * may list with an empty key (local Ollama-style servers).
 */
export async function listCloudModels(
  provider: string,
  apiKey: string,
  fetchImplOrOpts?: FetchLike | ListCloudModelsOptions,
  signal?: AbortSignal,
): Promise<ListedCloudModel[]> {
  // Back-compat: (provider, key, fetchImpl, signal) or (provider, key, opts)
  let fetchImpl: FetchLike = globalThis.fetch.bind(globalThis) as FetchLike;
  let baseUrl: string | undefined;
  let apiStyle: CustomApiStyle | undefined;
  let abort = signal;

  if (typeof fetchImplOrOpts === "function") {
    fetchImpl = fetchImplOrOpts;
  } else if (fetchImplOrOpts && typeof fetchImplOrOpts === "object") {
    if (fetchImplOrOpts.fetchImpl) fetchImpl = fetchImplOrOpts.fetchImpl;
    baseUrl = fetchImplOrOpts.baseUrl;
    apiStyle = fetchImplOrOpts.apiStyle;
    if (fetchImplOrOpts.signal) abort = fetchImplOrOpts.signal;
  }

  const key = (apiKey || "").trim();
  if (provider === "localMetal" || provider === "local-metal") {
    return [];
  }

  const override = baseUrl?.replace(/\/+$/, "");

  try {
    if (override) {
      const style = apiStyle === "anthropic" ? "anthropic" : "openai";
      // Local / custom hosts often accept empty keys.
      if (style === "anthropic") {
        return await listAnthropicAt(override, key || "none", fetchImpl, abort);
      }
      return await listOpenAICompatible(override, key || "none", fetchImpl, abort);
    }

    if (!key) return [];

    if (provider === "anthropic") {
      return await listAnthropicAt("https://api.anthropic.com/v1", key, fetchImpl, abort);
    }
    if (provider === "google") {
      return await listGoogle(key, fetchImpl, abort);
    }
    const base = OPENAI_BASE[provider];
    if (!base) return [];
    return await listOpenAICompatible(base, key, fetchImpl, abort);
  } catch {
    return [];
  }
}

async function listAnthropicAt(
  base: string,
  apiKey: string,
  fetchImpl: FetchLike,
  signal?: AbortSignal,
): Promise<ListedCloudModel[]> {
  const res = await fetchImpl(`${base.replace(/\/+$/, "")}/models`, {
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    signal,
  });
  if (!res.ok) return [];
  const json = (await res.json()) as { data?: Array<{ id?: string; display_name?: string }> };
  const rows = Array.isArray(json.data) ? json.data : [];
  return rows
    .filter((r) => typeof r.id === "string" && r.id.length > 0)
    .map((r) => ({
      id: r.id!,
      displayName: (r.display_name || r.id!).trim(),
    }));
}

async function listOpenAICompatible(
  base: string,
  apiKey: string,
  fetchImpl: FetchLike,
  signal?: AbortSignal,
): Promise<ListedCloudModel[]> {
  const res = await fetchImpl(`${base.replace(/\/+$/, "")}/models`, {
    headers: { authorization: `Bearer ${apiKey}` },
    signal,
  });
  if (!res.ok) return [];
  const json = (await res.json()) as { data?: Array<{ id?: string }> };
  const rows = Array.isArray(json.data) ? json.data : [];
  return rows
    .filter((r) => typeof r.id === "string" && r.id.length > 0)
    .map((r) => ({ id: r.id!, displayName: r.id! }))
    .slice(0, 80);
}

async function listGoogle(
  apiKey: string,
  fetchImpl: FetchLike,
  signal?: AbortSignal,
): Promise<ListedCloudModel[]> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models?key=${encodeURIComponent(apiKey)}`;
  const res = await fetchImpl(url, { signal });
  if (!res.ok) return [];
  const json = (await res.json()) as {
    models?: Array<{ name?: string; displayName?: string; supportedGenerationMethods?: string[] }>;
  };
  const rows = Array.isArray(json.models) ? json.models : [];
  return rows
    .filter((m) => (m.supportedGenerationMethods ?? []).includes("generateContent"))
    .map((m) => {
      const raw = (m.name || "").replace(/^models\//, "");
      return {
        id: raw,
        displayName: (m.displayName || raw).trim(),
      };
    })
    .filter((m) => m.id.length > 0);
}

/** Whether a chat selection is usable (not an empty / fake placeholder). */
export function isUsableChatSelection(
  provider: string,
  model: string,
  opts: {
    hasProviderKey: boolean;
    metalDownloadedIds?: Set<string> | string[];
    /** Custom provider is configured with a base URL (key optional). */
    customConfigured?: boolean;
  },
): boolean {
  if (!provider || !model?.trim()) return false;
  if (provider === "localMetal" || provider === "local-metal") {
    const set =
      opts.metalDownloadedIds instanceof Set
        ? opts.metalDownloadedIds
        : new Set(opts.metalDownloadedIds ?? []);
    return set.has(model) || set.has(model.replace(/^lmstudio-community\//, ""));
  }
  if (provider.startsWith("custom:")) {
    return opts.customConfigured === true || opts.hasProviderKey;
  }
  return opts.hasProviderKey;
}
