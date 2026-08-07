/**
 * List real models for a keyed cloud provider (renderer / unit-testable).
 * Returns [] when the key is missing, the provider is unsupported, or the API fails.
 * Never invents static “default” model ids.
 */
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
};

export type FetchLike = (
  input: string,
  init?: { headers?: Record<string, string>; signal?: AbortSignal },
) => Promise<{ ok: boolean; status: number; json: () => Promise<unknown> }>;

/**
 * Fetch models for a BYOK provider. Empty when key is blank or listing fails.
 */
export async function listCloudModels(
  provider: string,
  apiKey: string,
  fetchImpl: FetchLike = globalThis.fetch.bind(globalThis) as FetchLike,
  signal?: AbortSignal,
): Promise<ListedCloudModel[]> {
  const key = (apiKey || "").trim();
  if (!key || provider === "localMetal" || provider === "local-metal") {
    return [];
  }

  try {
    if (provider === "anthropic") {
      return await listAnthropic(key, fetchImpl, signal);
    }
    if (provider === "google") {
      return await listGoogle(key, fetchImpl, signal);
    }
    const base = OPENAI_BASE[provider];
    if (!base) return [];
    return await listOpenAICompatible(base, key, fetchImpl, signal);
  } catch {
    return [];
  }
}

async function listAnthropic(
  apiKey: string,
  fetchImpl: FetchLike,
  signal?: AbortSignal,
): Promise<ListedCloudModel[]> {
  const res = await fetchImpl("https://api.anthropic.com/v1/models", {
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
  return opts.hasProviderKey;
}
