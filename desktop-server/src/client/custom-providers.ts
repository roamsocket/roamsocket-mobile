/**
 * User-defined (custom) LLM endpoints for the desktop client.
 *
 * Mirrors iOS `CustomProvider`: persisted metadata (label, base URL, API style)
 * lives in storage; API keys use the existing secrets map under `custom:<slug>`.
 *
 * Pure helpers — injectable StorageLike for unit tests (no Electron/DOM).
 */
import type { StorageLike } from "./history-store.js";

const KEY = "apc.customProviders.v1";

/** HTTP shape for chat/completions vs Anthropic messages. */
export type CustomApiStyle = "openai" | "anthropic";

export interface CustomProvider {
  /** Stable slug without the `custom:` prefix (e.g. `ollama`). */
  id: string;
  /** Display name in Settings and pickers. */
  label: string;
  /**
   * Base URL including the version segment, e.g. `http://localhost:11434/v1`.
   * Do not include `/chat/completions` or `/messages`.
   */
  baseUrl: string;
  apiStyle: CustomApiStyle;
  /** Optional default model id for this endpoint. */
  defaultModel?: string;
}

export interface ResolvedEndpoint {
  baseUrl: string;
  apiStyle: CustomApiStyle;
}

function stripTrailingSlash(url: string): string {
  return url.replace(/\/+$/, "");
}

/** Wire / secrets id for a custom provider. */
export function customProviderId(slug: string): string {
  const s = slug.trim().toLowerCase().replace(/^custom:/, "");
  return `custom:${s}`;
}

/** Extract slug from `custom:<slug>`, or null if not a custom id. */
export function customSlugFromProviderId(providerId: string): string | null {
  if (!providerId.startsWith("custom:")) return null;
  const slug = providerId.slice("custom:".length).trim();
  return slug.length > 0 ? slug : null;
}

export function isCustomProviderId(providerId: string): boolean {
  return customSlugFromProviderId(providerId) != null;
}

/** Normalize user input into a safe slug (alphanumeric + hyphen/underscore). */
export function slugifyProviderLabel(label: string): string {
  const raw = label
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48);
  return raw || "custom";
}

function normalizeRecord(raw: unknown): CustomProvider | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const id = typeof o.id === "string" ? o.id.trim().replace(/^custom:/, "") : "";
  const label = typeof o.label === "string" ? o.label.trim() : "";
  const baseUrl = typeof o.baseUrl === "string" ? stripTrailingSlash(o.baseUrl.trim()) : "";
  const styleRaw = typeof o.apiStyle === "string" ? o.apiStyle : "openai";
  const apiStyle: CustomApiStyle = styleRaw === "anthropic" ? "anthropic" : "openai";
  if (!id || !label || !baseUrl) return null;
  const defaultModel =
    typeof o.defaultModel === "string" && o.defaultModel.trim()
      ? o.defaultModel.trim()
      : undefined;
  return { id, label, baseUrl, apiStyle, defaultModel };
}

export function loadCustomProviders(storage: StorageLike): CustomProvider[] {
  try {
    const raw = storage.getItem(KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    const out: CustomProvider[] = [];
    const seen = new Set<string>();
    for (const item of parsed) {
      const rec = normalizeRecord(item);
      if (!rec || seen.has(rec.id)) continue;
      seen.add(rec.id);
      out.push(rec);
    }
    return out;
  } catch {
    return [];
  }
}

export function saveCustomProviders(storage: StorageLike, list: CustomProvider[]): void {
  storage.setItem(KEY, JSON.stringify(list));
}

export function findCustomProvider(
  storage: StorageLike,
  providerIdOrSlug: string,
): CustomProvider | undefined {
  const slug =
    customSlugFromProviderId(providerIdOrSlug) ??
    providerIdOrSlug.replace(/^custom:/, "").trim();
  if (!slug) return undefined;
  return loadCustomProviders(storage).find((p) => p.id === slug);
}

/**
 * Create a custom provider. Returns null if validation fails or id collides.
 * Does not store API keys — caller uses secrets under `customProviderId(id)`.
 */
export function addCustomProvider(
  storage: StorageLike,
  input: {
    label: string;
    baseUrl: string;
    apiStyle?: CustomApiStyle;
    id?: string;
    defaultModel?: string;
  },
): CustomProvider | null {
  const label = input.label.trim();
  const baseUrl = stripTrailingSlash((input.baseUrl || "").trim());
  if (!label || !baseUrl) return null;
  try {
    // Basic URL sanity (allows http localhost).
    const u = new URL(baseUrl);
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  } catch {
    return null;
  }
  const list = loadCustomProviders(storage);
  let id = (input.id ?? slugifyProviderLabel(label)).trim().replace(/^custom:/, "");
  id = id.toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "") || "custom";
  if (list.some((p) => p.id === id)) {
    let n = 2;
    while (list.some((p) => p.id === `${id}-${n}`)) n += 1;
    id = `${id}-${n}`;
  }
  const rec: CustomProvider = {
    id,
    label,
    baseUrl,
    apiStyle: input.apiStyle === "anthropic" ? "anthropic" : "openai",
    defaultModel: input.defaultModel?.trim() || undefined,
  };
  list.push(rec);
  saveCustomProviders(storage, list);
  return rec;
}

export function updateCustomProvider(
  storage: StorageLike,
  id: string,
  patch: Partial<Pick<CustomProvider, "label" | "baseUrl" | "apiStyle" | "defaultModel">>,
): CustomProvider | null {
  const slug = id.replace(/^custom:/, "").trim();
  const list = loadCustomProviders(storage);
  const idx = list.findIndex((p) => p.id === slug);
  if (idx < 0) return null;
  const cur = list[idx]!;
  const next: CustomProvider = { ...cur };
  if (typeof patch.label === "string" && patch.label.trim()) next.label = patch.label.trim();
  if (typeof patch.baseUrl === "string" && patch.baseUrl.trim()) {
    const baseUrl = stripTrailingSlash(patch.baseUrl.trim());
    try {
      const u = new URL(baseUrl);
      if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    } catch {
      return null;
    }
    next.baseUrl = baseUrl;
  }
  if (patch.apiStyle === "openai" || patch.apiStyle === "anthropic") {
    next.apiStyle = patch.apiStyle;
  }
  if (patch.defaultModel !== undefined) {
    next.defaultModel = patch.defaultModel.trim() || undefined;
  }
  list[idx] = next;
  saveCustomProviders(storage, list);
  return next;
}

export function removeCustomProvider(storage: StorageLike, id: string): boolean {
  const slug = id.replace(/^custom:/, "").trim();
  const list = loadCustomProviders(storage);
  const next = list.filter((p) => p.id !== slug);
  if (next.length === list.length) return false;
  saveCustomProviders(storage, next);
  return true;
}

/**
 * Resolve base URL + API style for a provider id.
 * Custom providers always need a configured base URL; built-ins return empty
 * unless an explicit override is passed (proxy hosts).
 */
export function resolveProviderEndpoint(
  providerId: string,
  customs: CustomProvider[],
  overrides?: { baseUrl?: string; apiStyle?: CustomApiStyle },
): ResolvedEndpoint | null {
  const overrideBase = overrides?.baseUrl?.trim()
    ? stripTrailingSlash(overrides.baseUrl.trim())
    : "";
  if (overrideBase) {
    const style: CustomApiStyle =
      overrides?.apiStyle === "anthropic"
        ? "anthropic"
        : overrides?.apiStyle === "openai"
          ? "openai"
          : providerId === "anthropic"
            ? "anthropic"
            : "openai";
    return { baseUrl: overrideBase, apiStyle: style };
  }
  const slug = customSlugFromProviderId(providerId);
  if (slug) {
    const found = customs.find((c) => c.id === slug);
    if (!found?.baseUrl) return null;
    return {
      baseUrl: stripTrailingSlash(found.baseUrl),
      apiStyle: found.apiStyle === "anthropic" ? "anthropic" : "openai",
    };
  }
  return null;
}

/**
 * Chat/completions HTTP target for a provider + optional endpoint override.
 * Pure function used by streamChat and unit tests (never hits network).
 */
export function chatRequestTarget(
  provider: string,
  endpoint?: ResolvedEndpoint | null,
): { style: "openai" | "anthropic" | "google" | "metal"; url: string } | { style: "error"; message: string } {
  if (provider === "localMetal" || provider === "local-metal") {
    return { style: "metal", url: "" };
  }
  if (endpoint?.baseUrl) {
    const base = stripTrailingSlash(endpoint.baseUrl);
    if (endpoint.apiStyle === "anthropic") {
      return { style: "anthropic", url: `${base}/messages` };
    }
    return { style: "openai", url: `${base}/chat/completions` };
  }
  if (provider.startsWith("custom:")) {
    return {
      style: "error",
      message: `Custom provider "${provider}" needs a baseUrl (set in Settings → Providers).`,
    };
  }
  if (provider === "anthropic") {
    return { style: "anthropic", url: "https://api.anthropic.com/v1/messages" };
  }
  if (provider === "google") {
    return { style: "google", url: "https://generativelanguage.googleapis.com/v1beta" };
  }
  const OPENAI_BASE: Record<string, string> = {
    openai: "https://api.openai.com/v1",
    groq: "https://api.groq.com/openai/v1",
    openrouter: "https://openrouter.ai/api/v1",
    xai: "https://api.x.ai/v1",
    mistral: "https://api.mistral.ai/v1",
    minimax: "https://api.minimax.io/v1",
  };
  const base = OPENAI_BASE[provider] ?? OPENAI_BASE.openai!;
  return { style: "openai", url: `${base}/chat/completions` };
}

/** Label for any provider id (built-in or custom). */
export function customOrBuiltinLabel(
  providerId: string,
  customs: CustomProvider[],
  builtinLabel: (id: string) => string,
): string {
  const slug = customSlugFromProviderId(providerId);
  if (slug) {
    return customs.find((c) => c.id === slug)?.label ?? providerId;
  }
  return builtinLabel(providerId);
}
