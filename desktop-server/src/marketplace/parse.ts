/**
 * Parse + merge marketplace catalogs (pure; safe for unit tests).
 */
import { BUNDLED_MARKETPLACE_CATALOG } from "./defaults.js";
import {
  emptyCatalog,
  MARKETPLACE_SCHEMA_VERSION,
  type MarketplaceCatalog,
  type MarketplaceConnector,
  type MarketplaceMetalModel,
  type MarketplacePlugin,
  type MarketplacePluginCategory,
  type MarketplaceSkill,
} from "./types.js";

function asString(v: unknown, fallback = ""): string {
  return typeof v === "string" ? v : fallback;
}

function asBool(v: unknown, fallback: boolean): boolean {
  return typeof v === "boolean" ? v : fallback;
}

function asStringArray(v: unknown): string[] | undefined {
  if (!Array.isArray(v)) return undefined;
  return v.filter((x): x is string => typeof x === "string");
}

function parseConnectors(raw: unknown): MarketplaceConnector[] {
  if (!Array.isArray(raw)) return [];
  const out: MarketplaceConnector[] = [];
  for (const row of raw) {
    if (!row || typeof row !== "object") continue;
    const o = row as Record<string, unknown>;
    const id = asString(o.id).trim();
    const name = asString(o.name).trim();
    if (!id || !name) continue;
    out.push({
      id,
      name,
      description: asString(o.description) || undefined,
      icon: asString(o.icon) || undefined,
      available: asBool(o.available, true),
      category: asString(o.category) || undefined,
    });
  }
  return out;
}

function parseSkills(raw: unknown): MarketplaceSkill[] {
  if (!Array.isArray(raw)) return [];
  const out: MarketplaceSkill[] = [];
  for (const row of raw) {
    if (!row || typeof row !== "object") continue;
    const o = row as Record<string, unknown>;
    const id = asString(o.id).trim();
    const name = asString(o.name).trim() || id;
    if (!id) continue;
    out.push({
      id,
      name,
      description: asString(o.description),
      category: asString(o.category) || undefined,
      author: asString(o.author) || undefined,
      source: asString(o.source) || undefined,
      featured: asBool(o.featured, false),
      instructions: asString(o.instructions) || undefined,
    });
  }
  return out;
}

function parsePlugins(raw: unknown): MarketplacePlugin[] {
  if (!Array.isArray(raw)) return [];
  const out: MarketplacePlugin[] = [];
  for (const row of raw) {
    if (!row || typeof row !== "object") continue;
    const o = row as Record<string, unknown>;
    const id = asString(o.id).trim();
    const name = asString(o.name).trim() || id;
    if (!id) continue;
    out.push({
      id,
      name,
      description: asString(o.description) || undefined,
      category: asString(o.category) || undefined,
      skillIds: asStringArray(o.skillIds),
      featured: asBool(o.featured, false),
    });
  }
  return out;
}

function parsePluginCategories(raw: unknown): MarketplacePluginCategory[] {
  if (!Array.isArray(raw)) return [];
  const out: MarketplacePluginCategory[] = [];
  for (const row of raw) {
    if (!row || typeof row !== "object") continue;
    const o = row as Record<string, unknown>;
    const id = asString(o.id).trim();
    const label = asString(o.label).trim() || id;
    if (!id) continue;
    out.push({ id, label });
  }
  return out;
}

function parseMetalModels(raw: unknown): MarketplaceMetalModel[] {
  if (!Array.isArray(raw)) return [];
  const out: MarketplaceMetalModel[] = [];
  for (const row of raw) {
    if (!row || typeof row !== "object") continue;
    const o = row as Record<string, unknown>;
    const hubID = asString(o.hubID).trim();
    const displayName = asString(o.displayName).trim() || hubID;
    if (!hubID.includes("/")) continue;
    out.push({
      hubID,
      displayName,
      approxSize: asString(o.approxSize) || undefined,
      blurb: asString(o.blurb) || undefined,
      tags: asStringArray(o.tags),
      platforms: asStringArray(o.platforms),
    });
  }
  return out;
}

/** Parse unknown JSON into a catalog; returns null if completely unusable. */
export function parseMarketplaceCatalog(raw: unknown): MarketplaceCatalog | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const schemaVersion =
    typeof o.schemaVersion === "number" && Number.isFinite(o.schemaVersion)
      ? o.schemaVersion
      : MARKETPLACE_SCHEMA_VERSION;
  if (schemaVersion > MARKETPLACE_SCHEMA_VERSION + 2) {
    // Far-future schema — refuse rather than mis-merge.
    return null;
  }
  return emptyCatalog({
    schemaVersion,
    updatedAt: asString(o.updatedAt) || undefined,
    name: asString(o.name) || undefined,
    description: asString(o.description) || undefined,
    connectors: parseConnectors(o.connectors),
    skills: parseSkills(o.skills),
    plugins: parsePlugins(o.plugins),
    pluginCategories: parsePluginCategories(o.pluginCategories),
    metalModels: parseMetalModels(o.metalModels),
  });
}

function upsertById<T extends { id: string }>(map: Map<string, T>, items: T[]): void {
  for (const item of items) {
    map.set(item.id, item);
  }
}

/**
 * Merge catalogs in order. Later catalogs override earlier entries with the
 * same connector/skill/plugin id or metal hubID.
 */
export function mergeMarketplaceCatalogs(catalogs: MarketplaceCatalog[]): MarketplaceCatalog {
  if (catalogs.length === 0) {
    return structuredClone(BUNDLED_MARKETPLACE_CATALOG);
  }
  const connectors = new Map<string, MarketplaceConnector>();
  const skills = new Map<string, MarketplaceSkill>();
  const plugins = new Map<string, MarketplacePlugin>();
  const pluginCategories = new Map<string, MarketplacePluginCategory>();
  const metal = new Map<string, MarketplaceMetalModel>();

  let name: string | undefined;
  let description: string | undefined;
  let updatedAt: string | undefined;

  for (const c of catalogs) {
    if (c.name) name = c.name;
    if (c.description) description = c.description;
    if (c.updatedAt) updatedAt = c.updatedAt;
    upsertById(connectors, c.connectors);
    upsertById(skills, c.skills);
    upsertById(plugins, c.plugins);
    upsertById(pluginCategories, c.pluginCategories);
    for (const m of c.metalModels) {
      metal.set(m.hubID, m);
    }
  }

  return emptyCatalog({
    schemaVersion: MARKETPLACE_SCHEMA_VERSION,
    name: name ?? "Merged marketplace",
    description,
    updatedAt,
    connectors: [...connectors.values()],
    skills: [...skills.values()],
    plugins: [...plugins.values()],
    pluginCategories: [...pluginCategories.values()],
    metalModels: [...metal.values()],
  });
}

/** Normalize a user-entered catalog URL. */
export function normalizeMarketplaceUrl(input: string): string {
  let u = input.trim();
  // Accept github.com/owner/repo blob links → raw
  // https://github.com/o/r/blob/main/marketplace/catalog.json
  const blob = u.match(
    /^https?:\/\/github\.com\/([^/]+)\/([^/]+)\/blob\/([^/]+)\/(.+)$/i,
  );
  if (blob) {
    const [, owner, repo, branch, pathPart] = blob;
    u = `https://raw.githubusercontent.com/${owner}/${repo}/${branch}/${pathPart}`;
  }
  // Accept tree links ending without file → append catalog.json
  const tree = u.match(
    /^https?:\/\/github\.com\/([^/]+)\/([^/]+)\/tree\/([^/]+)\/?(.*)$/i,
  );
  if (tree) {
    const [, owner, repo, branch, rest] = tree;
    const pathPart = (rest ?? "").replace(/\/$/, "");
    const file = pathPart
      ? pathPart.endsWith(".json")
        ? pathPart
        : `${pathPart}/catalog.json`
      : "catalog.json";
    u = `https://raw.githubusercontent.com/${owner}/${repo}/${branch}/${file}`;
  }
  // Bare owner/repo → root catalog.json (official layout); nested marketplace/ also works via tree/blob links.
  if (/^[\w.-]+\/[\w.-]+$/.test(u)) {
    u = `https://raw.githubusercontent.com/${u}/main/catalog.json`;
  }
  return u;
}

export function isValidMarketplaceUrl(url: string): boolean {
  try {
    const u = new URL(url);
    return u.protocol === "https:" || u.protocol === "http:";
  } catch {
    return false;
  }
}

/** Filter metal models by target platform (omit platforms = both). */
export function metalModelsForPlatform(
  catalog: MarketplaceCatalog,
  platform: "ios" | "desktop",
): MarketplaceMetalModel[] {
  return catalog.metalModels.filter((m) => {
    const plats = m.platforms;
    if (!plats || plats.length === 0) return true;
    return plats.map(String).includes(platform);
  });
}
