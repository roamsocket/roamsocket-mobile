/**
 * Shared marketplace catalog types (connectors, skills, plugins, Metal models).
 * Schema mirrors the official marketplace catalog.json (GitHub raw URL below).
 */

export const MARKETPLACE_SCHEMA_VERSION = 1;

/**
 * Default raw catalog URL for the official RoamSocket marketplace.
 * Host path is the external GitHub location (not product branding).
 */
export const DEFAULT_MARKETPLACE_URL =
  'https://raw.githubusercontent.com/roamsocket-ai/roamsocket-marketplace/main/catalog.json';

export const DEFAULT_MARKETPLACE_SOURCE_ID = 'roamsocket-official';
/** LEGACY default source ids — remapped on load so users keep one official entry. */
export const LEGACY_MARKETPLACE_SOURCE_IDS = ['roamsocket-official'] as const;

export type MetalTag =
  | 'recommended'
  | 'best'
  | 'thinking'
  | 'vision'
  | 'new'
  | 'experimental'
  | 'legacy';

export type MetalPlatform = 'ios' | 'desktop';

export interface MarketplaceConnector {
  id: string;
  name: string;
  description?: string;
  icon?: string;
  available?: boolean;
  category?: string;
}

export interface MarketplaceSkill {
  id: string;
  name: string;
  description: string;
  category?: string;
  author?: string;
  source?: 'official' | 'community' | 'custom' | string;
  featured?: boolean;
  /** Optional longer instructions for install-from-marketplace flows. */
  instructions?: string;
}

export interface MarketplacePlugin {
  id: string;
  name: string;
  description?: string;
  category?: string;
  skillIds?: string[];
  featured?: boolean;
}

export interface MarketplacePluginCategory {
  id: string;
  label: string;
}

export interface MarketplaceMetalModel {
  hubID: string;
  displayName: string;
  approxSize?: string;
  blurb?: string;
  tags?: MetalTag[] | string[];
  platforms?: MetalPlatform[] | string[];
}

export interface MarketplaceCatalog {
  schemaVersion: number;
  updatedAt?: string;
  name?: string;
  description?: string;
  connectors: MarketplaceConnector[];
  skills: MarketplaceSkill[];
  plugins: MarketplacePlugin[];
  pluginCategories: MarketplacePluginCategory[];
  metalModels: MarketplaceMetalModel[];
}

/** One configured marketplace source (default or user-added). */
export interface MarketplaceSource {
  id: string;
  /** Display name in Settings. */
  name: string;
  /** Full URL to catalog.json (raw GitHub, HTTP, or file URL). */
  url: string;
  enabled: boolean;
  /** Built-in RoamSocket official — cannot be deleted, only disabled. */
  isDefault?: boolean;
  lastFetchedAt?: number;
  lastError?: string | null;
  /** Catalog name from last successful fetch. */
  catalogName?: string | null;
}

export interface MarketplaceSourcesFile {
  version: 1;
  sources: MarketplaceSource[];
}

export interface MarketplaceStatus {
  sources: MarketplaceSource[];
  catalog: MarketplaceCatalog;
  /** When the merged catalog was last successfully refreshed. */
  lastMergedAt: number | null;
  /** True when serving only bundled defaults (no successful remote fetch). */
  usingBundledOnly: boolean;
}

export function emptyCatalog(partial?: Partial<MarketplaceCatalog>): MarketplaceCatalog {
  return {
    schemaVersion: MARKETPLACE_SCHEMA_VERSION,
    updatedAt: partial?.updatedAt,
    name: partial?.name,
    description: partial?.description,
    connectors: partial?.connectors ?? [],
    skills: partial?.skills ?? [],
    plugins: partial?.plugins ?? [],
    pluginCategories: partial?.pluginCategories ?? [],
    metalModels: partial?.metalModels ?? [],
  };
}
