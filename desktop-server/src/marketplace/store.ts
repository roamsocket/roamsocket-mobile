/**
 * Multi-source marketplace store: default GitHub catalog + user-added repos.
 * Persists sources + last merged catalog under the product data dir.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { productDataPath } from "../product.js";
import { BUNDLED_MARKETPLACE_CATALOG } from "./defaults.js";
import {
  isValidMarketplaceUrl,
  mergeMarketplaceCatalogs,
  normalizeMarketplaceUrl,
  parseMarketplaceCatalog,
} from "./parse.js";
import {
  DEFAULT_MARKETPLACE_SOURCE_ID,
  DEFAULT_MARKETPLACE_URL,
  LEGACY_MARKETPLACE_SOURCE_IDS,
  emptyCatalog,
  type MarketplaceCatalog,
  type MarketplaceSource,
  type MarketplaceSourcesFile,
  type MarketplaceStatus,
} from "./types.js";

const SOURCES_FILE = "marketplace-sources.json";
const CACHE_FILE = "marketplace-cache.json";

interface CacheFile {
  version: 1;
  lastMergedAt: number | null;
  usingBundledOnly: boolean;
  catalog: MarketplaceCatalog;
  /** Per-source last successful catalog (for offline merge). */
  perSource?: Record<string, MarketplaceCatalog>;
}

function sourcesPath(): string {
  return productDataPath(SOURCES_FILE);
}

function cachePath(): string {
  return productDataPath(CACHE_FILE);
}

function defaultSourceUrl(): string {
  const env = process.env.APC_MARKETPLACE_URL;
  if (env !== undefined) {
    const t = env.trim();
    if (t.length === 0) return ""; // explicit: no remote default
    return normalizeMarketplaceUrl(t);
  }
  return DEFAULT_MARKETPLACE_URL;
}

export function makeDefaultSource(): MarketplaceSource {
  const url = defaultSourceUrl();
  return {
    id: DEFAULT_MARKETPLACE_SOURCE_ID,
    name: "RoamSocket Official",
    url: url || DEFAULT_MARKETPLACE_URL,
    enabled: url.length > 0,
    isDefault: true,
    lastError: null,
    catalogName: null,
  };
}

function isOfficialSourceId(id: string): boolean {
  return (
    id === DEFAULT_MARKETPLACE_SOURCE_ID ||
    (LEGACY_MARKETPLACE_SOURCE_IDS as readonly string[]).includes(id)
  );
}

function ensureDefaultInList(sources: MarketplaceSource[]): MarketplaceSource[] {
  const def = makeDefaultSource();
  const without = sources.filter((s) => !s.isDefault && !isOfficialSourceId(s.id));
  const existing = sources.find((s) => s.isDefault || isOfficialSourceId(s.id));
  if (existing) {
    // Keep user enable/disable + custom name; refresh default URL from env if set.
    // Remap LEGACY marketplace source ids onto DEFAULT_MARKETPLACE_SOURCE_ID.
    const urlFromEnv = process.env.APC_MARKETPLACE_URL;
    return [
      {
        ...existing,
        isDefault: true,
        id: DEFAULT_MARKETPLACE_SOURCE_ID,
        url:
          urlFromEnv !== undefined
            ? urlFromEnv.trim()
              ? normalizeMarketplaceUrl(urlFromEnv.trim())
              : existing.url
            : existing.url || def.url,
        name: existing.name || def.name,
      },
      ...without,
    ];
  }
  return [def, ...without];
}

function loadSourcesFile(): MarketplaceSource[] {
  try {
    const p = sourcesPath();
    if (!existsSync(p)) return ensureDefaultInList([]);
    const parsed = JSON.parse(readFileSync(p, "utf8")) as Partial<MarketplaceSourcesFile>;
    const list = Array.isArray(parsed.sources) ? parsed.sources : [];
    return ensureDefaultInList(
      list
        .filter((s) => s && typeof s === "object" && typeof s.id === "string")
        .map((s) => ({
          id: s.id,
          name: typeof s.name === "string" && s.name.trim() ? s.name.trim() : s.id,
          url: typeof s.url === "string" ? s.url : "",
          enabled: s.enabled !== false,
          isDefault: !!s.isDefault,
          lastFetchedAt: typeof s.lastFetchedAt === "number" ? s.lastFetchedAt : undefined,
          lastError: s.lastError ?? null,
          catalogName: s.catalogName ?? null,
        })),
    );
  } catch {
    return ensureDefaultInList([]);
  }
}

function saveSourcesFile(sources: MarketplaceSource[]): void {
  try {
    const dir = path.dirname(sourcesPath());
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const body: MarketplaceSourcesFile = { version: 1, sources };
    writeFileSync(sourcesPath(), JSON.stringify(body, null, 2));
  } catch {
    // best effort
  }
}

function loadCache(): CacheFile {
  try {
    const p = cachePath();
    if (!existsSync(p)) {
      return {
        version: 1,
        lastMergedAt: null,
        usingBundledOnly: true,
        catalog: structuredClone(BUNDLED_MARKETPLACE_CATALOG),
        perSource: {},
      };
    }
    const parsed = JSON.parse(readFileSync(p, "utf8")) as Partial<CacheFile>;
    const catalog = parseMarketplaceCatalog(parsed.catalog) ?? structuredClone(BUNDLED_MARKETPLACE_CATALOG);
    return {
      version: 1,
      lastMergedAt: typeof parsed.lastMergedAt === "number" ? parsed.lastMergedAt : null,
      usingBundledOnly: parsed.usingBundledOnly !== false && !parsed.lastMergedAt,
      catalog,
      perSource:
        parsed.perSource && typeof parsed.perSource === "object"
          ? (parsed.perSource as Record<string, MarketplaceCatalog>)
          : {},
    };
  } catch {
    return {
      version: 1,
      lastMergedAt: null,
      usingBundledOnly: true,
      catalog: structuredClone(BUNDLED_MARKETPLACE_CATALOG),
      perSource: {},
    };
  }
}

function saveCache(cache: CacheFile): void {
  try {
    const dir = path.dirname(cachePath());
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    writeFileSync(cachePath(), JSON.stringify(cache, null, 2));
  } catch {
    // best effort
  }
}

async function fetchCatalogUrl(url: string, timeoutMs = 20_000): Promise<MarketplaceCatalog> {
  if (!isValidMarketplaceUrl(url)) {
    throw new Error("Invalid marketplace URL");
  }
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      signal: ctrl.signal,
      headers: {
        Accept: "application/json",
        "User-Agent": "RoamSocket-desktop/marketplace",
      },
    });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status} fetching marketplace`);
    }
    const json: unknown = await res.json();
    const catalog = parseMarketplaceCatalog(json);
    if (!catalog) throw new Error("catalog.json did not match the marketplace schema");
    return catalog;
  } finally {
    clearTimeout(t);
  }
}

export class MarketplaceStore {
  private sources: MarketplaceSource[];
  private cache: CacheFile;

  constructor() {
    this.sources = loadSourcesFile();
    this.cache = loadCache();
  }

  listSources(): MarketplaceSource[] {
    return this.sources.map((s) => ({ ...s }));
  }

  getCatalog(): MarketplaceCatalog {
    return this.cache.catalog;
  }

  status(): MarketplaceStatus {
    return {
      sources: this.listSources(),
      catalog: this.getCatalog(),
      lastMergedAt: this.cache.lastMergedAt,
      usingBundledOnly: this.cache.usingBundledOnly,
    };
  }

  addSource(input: { name?: string; url: string; enabled?: boolean }): MarketplaceSource {
    const url = normalizeMarketplaceUrl(input.url);
    if (!isValidMarketplaceUrl(url)) {
      throw new Error("Enter a valid http(s) catalog URL, or owner/repo, or a GitHub blob/tree link.");
    }
    if (this.sources.some((s) => s.url === url)) {
      throw new Error("That marketplace URL is already added.");
    }
    const id = `user-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`;
    const src: MarketplaceSource = {
      id,
      name: (input.name?.trim() || deriveNameFromUrl(url)).slice(0, 80),
      url,
      enabled: input.enabled !== false,
      isDefault: false,
      lastError: null,
      catalogName: null,
    };
    this.sources = [...this.sources, src];
    saveSourcesFile(this.sources);
    return { ...src };
  }

  removeSource(id: string): void {
    const src = this.sources.find((s) => s.id === id);
    if (!src) throw new Error("Marketplace not found");
    if (src.isDefault || isOfficialSourceId(src.id)) {
      throw new Error("The official marketplace cannot be removed. Disable it instead.");
    }
    this.sources = this.sources.filter((s) => s.id !== id);
    if (this.cache.perSource?.[id]) {
      const next = { ...this.cache.perSource };
      delete next[id];
      this.cache.perSource = next;
      saveCache(this.cache);
    }
    saveSourcesFile(this.sources);
  }

  setSourceEnabled(id: string, enabled: boolean): MarketplaceSource {
    const idx = this.sources.findIndex((s) => s.id === id);
    if (idx < 0) throw new Error("Marketplace not found");
    const cur = this.sources[idx]!;
    const next = { ...cur, enabled };
    this.sources = this.sources.map((s, i) => (i === idx ? next : s));
    saveSourcesFile(this.sources);
    return { ...next };
  }

  setSourceUrl(id: string, urlRaw: string): MarketplaceSource {
    const idx = this.sources.findIndex((s) => s.id === id);
    if (idx < 0) throw new Error("Marketplace not found");
    const url = normalizeMarketplaceUrl(urlRaw);
    if (!isValidMarketplaceUrl(url)) throw new Error("Invalid marketplace URL");
    const cur = this.sources[idx]!;
    const next = { ...cur, url, lastError: null };
    this.sources = this.sources.map((s, i) => (i === idx ? next : s));
    saveSourcesFile(this.sources);
    return { ...next };
  }

  /**
   * Fetch every enabled source, merge (default → user order), cache, return status.
   * On total failure keeps previous cache / bundled defaults.
   */
  async refresh(): Promise<MarketplaceStatus> {
    const perSource: Record<string, MarketplaceCatalog> = { ...(this.cache.perSource ?? {}) };
    const fetched: MarketplaceCatalog[] = [];
    let anyRemoteOk = false;

    const updatedSources: MarketplaceSource[] = [];
    for (const src of this.sources) {
      if (!src.enabled || !src.url) {
        updatedSources.push({ ...src });
        continue;
      }
      try {
        const cat = await fetchCatalogUrl(src.url);
        anyRemoteOk = true;
        perSource[src.id] = cat;
        fetched.push(cat);
        updatedSources.push({
          ...src,
          lastFetchedAt: Date.now(),
          lastError: null,
          catalogName: cat.name ?? src.name,
        });
      } catch (err) {
        const message = String((err as Error).message ?? err);
        // Offline: reuse last good per-source catalog if present
        const cached = perSource[src.id];
        if (cached) {
          fetched.push(cached);
          anyRemoteOk = true;
        }
        updatedSources.push({
          ...src,
          lastError: message,
        });
      }
    }

    this.sources = updatedSources;
    saveSourcesFile(this.sources);

    // Always layer bundled first so disabled remotes still have a baseline.
    const catalogs: MarketplaceCatalog[] = [structuredClone(BUNDLED_MARKETPLACE_CATALOG), ...fetched];
    const merged = mergeMarketplaceCatalogs(catalogs);

    this.cache = {
      version: 1,
      lastMergedAt: anyRemoteOk ? Date.now() : this.cache.lastMergedAt,
      usingBundledOnly: !anyRemoteOk && fetched.length === 0,
      catalog: merged,
      perSource,
    };
    // If nothing remote worked and we had no per-source cache, still write merged = bundled
    if (!anyRemoteOk && fetched.length === 0) {
      this.cache.catalog = structuredClone(BUNDLED_MARKETPLACE_CATALOG);
      this.cache.usingBundledOnly = true;
    }
    saveCache(this.cache);
    return this.status();
  }
}

function deriveNameFromUrl(url: string): string {
  try {
    const u = new URL(url);
    const parts = u.pathname.split("/").filter(Boolean);
    // raw.githubusercontent.com/owner/repo/...
    if (u.hostname.includes("githubusercontent.com") && parts.length >= 2) {
      return `${parts[0]}/${parts[1]}`;
    }
    if (u.hostname === "github.com" && parts.length >= 2) {
      return `${parts[0]}/${parts[1]}`;
    }
    return u.hostname;
  } catch {
    return "Marketplace";
  }
}

let singleton: MarketplaceStore | null = null;

export function getMarketplaceStore(): MarketplaceStore {
  if (!singleton) singleton = new MarketplaceStore();
  return singleton;
}

/** Test helper */
export function resetMarketplaceStoreForTests(): void {
  singleton = null;
}

export { metalModelsForPlatform } from "./parse.js";
export { emptyCatalog } from "./types.js";
