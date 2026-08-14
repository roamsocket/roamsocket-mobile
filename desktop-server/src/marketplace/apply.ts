/**
 * Apply a merged marketplace catalog onto live desktop catalogs
 * (composer connectors / plugins, Metal model list).
 */
import {
  applyMarketplaceConnectors,
  applyMarketplacePluginCategories,
  type ConnectorCatalogEntry,
  type PluginCategory,
} from '../client/composer-tools.js';
import { setRemoteMetalCatalog, type MetalCatalogEntry, type MetalTag } from '../metal/catalog.js';
import { metalModelsForPlatform } from './parse.js';
import type { MarketplaceCatalog } from './types.js';

const KNOWN_TAGS = new Set<MetalTag>([
  'recommended',
  'best',
  'thinking',
  'vision',
  'new',
  'experimental',
  'legacy',
]);

export function applyMarketplaceToDesktop(catalog: MarketplaceCatalog): void {
  const connectors: ConnectorCatalogEntry[] = catalog.connectors.map((c) => ({
    id: c.id,
    name: c.name,
    available: c.available === false ? false : true,
  }));
  applyMarketplaceConnectors(connectors);

  const categories: PluginCategory[] =
    catalog.pluginCategories.length > 0
      ? catalog.pluginCategories.map((c) => ({ id: c.id, label: c.label }))
      : [];
  if (categories.length) applyMarketplacePluginCategories(categories);

  const metal: MetalCatalogEntry[] = metalModelsForPlatform(catalog, 'desktop').map((m) => ({
    hubID: m.hubID,
    displayName: m.displayName,
    approxSize: m.approxSize ?? '',
    blurb: m.blurb ?? '',
    tags: (m.tags ?? []).map(String).filter((t): t is MetalTag => KNOWN_TAGS.has(t as MetalTag)),
    chatOnly: true as const,
  }));
  setRemoteMetalCatalog(metal.length ? metal : null);
}
