/**
 * Chat composer + menu catalogs (skills, connectors, plugins) + local toggles.
 * Desktop-local UX parity with Claude’s attach menu — not full MCP auth.
 */
import type { StorageLike } from './history-store.js';
import { BUILTIN_SKILLS, type SkillRecord, skillByIdFromList } from './skills-store.js';

const KEY = 'apc.composerTools.v1';

export interface ComposerToolsState {
  webSearch: boolean;
  research: boolean;
  /** Connector id → enabled */
  connectors: Record<string, boolean>;
  /** Skill ids pinned / recently used (order preserved) */
  recentSkillIds: string[];
  /** Active skill ids for this chat session (applied as system guidance) */
  activeSkillIds: string[];
}

/** @deprecated Use SkillRecord from skills-store — kept for menu typing. */
export type SkillCatalogEntry = Pick<SkillRecord, 'id' | 'name' | 'description'>;

export interface ConnectorCatalogEntry {
  id: string;
  name: string;
  /** When true, shown greyed / off by default */
  available?: boolean;
}

export interface PluginCategory {
  id: string;
  label: string;
}

/** Built-in skill names for menus (resolved via SkillsStore for full content). */
export const SKILL_CATALOG: SkillCatalogEntry[] = BUILTIN_SKILLS.map((s) => ({
  id: s.id,
  name: s.name,
  description: s.description,
}));

/** Built-in connector list (overridden at runtime by marketplace merge). */
export const DEFAULT_CONNECTOR_CATALOG: ConnectorCatalogEntry[] = [
  { id: 'cashapp', name: 'Cash App' },
  { id: 'figma', name: 'Figma' },
  { id: 'gmail', name: 'Gmail' },
  { id: 'godaddy', name: 'GoDaddy' },
  { id: 'gcal', name: 'Google Calendar' },
  { id: 'gdrive', name: 'Google Drive' },
  { id: 'granola', name: 'Granola', available: false },
  { id: 'github', name: 'GitHub' },
];

/** Live connector catalog — marketplace applies updates in place. */
export let CONNECTOR_CATALOG: ConnectorCatalogEntry[] = [...DEFAULT_CONNECTOR_CATALOG];

export const DEFAULT_PLUGIN_CATEGORIES: PluginCategory[] = [
  { id: 'marketing', label: 'Marketing' },
  { id: 'productivity', label: 'Productivity' },
  { id: 'engineering', label: 'Engineering' },
  { id: 'design', label: 'Design' },
];

/** Live plugin categories — marketplace applies updates in place. */
export let PLUGIN_CATEGORIES: PluginCategory[] = [...DEFAULT_PLUGIN_CATEGORIES];

/** Replace connector catalog from a marketplace merge (non-empty only). */
export function applyMarketplaceConnectors(entries: ConnectorCatalogEntry[]): void {
  if (!entries.length) return;
  CONNECTOR_CATALOG = entries.map((c) => ({ ...c }));
}

/** Replace plugin categories from a marketplace merge (non-empty only). */
export function applyMarketplacePluginCategories(entries: PluginCategory[]): void {
  if (!entries.length) return;
  PLUGIN_CATEGORIES = entries.map((c) => ({ ...c }));
}

const DEFAULTS: ComposerToolsState = {
  webSearch: true,
  research: false,
  connectors: Object.fromEntries(
    DEFAULT_CONNECTOR_CATALOG.map((c) => [c.id, c.available === false ? false : true])
  ),
  recentSkillIds: [],
  activeSkillIds: [],
};

function defaultConnectorToggles(): Record<string, boolean> {
  return Object.fromEntries(
    CONNECTOR_CATALOG.map((c) => [c.id, c.available === false ? false : true])
  );
}

export function loadComposerTools(storage: StorageLike): ComposerToolsState {
  try {
    const raw = storage.getItem(KEY);
    const baseConnectors = defaultConnectorToggles();
    if (!raw) {
      return {
        webSearch: DEFAULTS.webSearch,
        research: DEFAULTS.research,
        connectors: baseConnectors,
        recentSkillIds: [],
        activeSkillIds: [],
      };
    }
    const parsed = JSON.parse(raw) as Partial<ComposerToolsState>;
    return {
      webSearch: parsed.webSearch ?? DEFAULTS.webSearch,
      research: parsed.research ?? DEFAULTS.research,
      connectors: { ...baseConnectors, ...(parsed.connectors ?? {}) },
      recentSkillIds: Array.isArray(parsed.recentSkillIds) ? parsed.recentSkillIds : [],
      activeSkillIds: Array.isArray(parsed.activeSkillIds) ? parsed.activeSkillIds : [],
    };
  } catch {
    return {
      webSearch: DEFAULTS.webSearch,
      research: DEFAULTS.research,
      connectors: defaultConnectorToggles(),
      recentSkillIds: [],
      activeSkillIds: [],
    };
  }
}

export function saveComposerTools(storage: StorageLike, state: ComposerToolsState): void {
  storage.setItem(KEY, JSON.stringify(state));
}

export function toggleConnector(
  storage: StorageLike,
  state: ComposerToolsState,
  id: string
): ComposerToolsState {
  const entry = CONNECTOR_CATALOG.find((c) => c.id === id);
  if (entry?.available === false) return state;
  const next = {
    ...state,
    connectors: { ...state.connectors, [id]: !state.connectors[id] },
  };
  saveComposerTools(storage, next);
  return next;
}

export function setWebSearch(
  storage: StorageLike,
  state: ComposerToolsState,
  on: boolean
): ComposerToolsState {
  const next = { ...state, webSearch: on };
  saveComposerTools(storage, next);
  return next;
}

export function setResearch(
  storage: StorageLike,
  state: ComposerToolsState,
  on: boolean
): ComposerToolsState {
  const next = { ...state, research: on };
  saveComposerTools(storage, next);
  return next;
}

export function activateSkill(
  storage: StorageLike,
  state: ComposerToolsState,
  skillId: string
): ComposerToolsState {
  const active = state.activeSkillIds.includes(skillId)
    ? state.activeSkillIds
    : [...state.activeSkillIds, skillId];
  const recent = [skillId, ...state.recentSkillIds.filter((id) => id !== skillId)].slice(0, 12);
  const next = { ...state, activeSkillIds: active, recentSkillIds: recent };
  saveComposerTools(storage, next);
  return next;
}

export function clearActiveSkills(
  storage: StorageLike,
  state: ComposerToolsState
): ComposerToolsState {
  const next = { ...state, activeSkillIds: [] };
  saveComposerTools(storage, next);
  return next;
}

export function skillById(id: string): SkillCatalogEntry | undefined {
  return (
    skillByIdFromList(BUILTIN_SKILLS, id) ?? SKILL_CATALOG.find((s) => s.id === id || s.name === id)
  );
}

/** System-prompt snippets from active tools for the next chat turn. */
export function composerToolsSystemHints(
  state: ComposerToolsState,
  resolveSkill?: (id: string) => SkillRecord | SkillCatalogEntry | undefined
): string[] {
  const parts: string[] = [];
  if (state.webSearch) {
    parts.push(
      'Web search is enabled for this chat. When facts may be outdated, say what you would look up and reason carefully.'
    );
  }
  if (state.research) {
    parts.push(
      'Research mode is on: prefer multi-source analysis, cite assumptions, and structure longer investigations.'
    );
  }
  const enabledConnectors = CONNECTOR_CATALOG.filter(
    (c) => state.connectors[c.id] && c.available !== false
  ).map((c) => c.name);
  if (enabledConnectors.length) {
    parts.push(
      `Enabled connectors (local preference): ${enabledConnectors.join(', ')}. Use them when the user asks for linked accounts; otherwise note when a live MCP connection is required.`
    );
  }
  const resolve = resolveSkill ?? skillById;
  const skills = state.activeSkillIds
    .map((id) => resolve(id))
    .filter((s): s is SkillRecord | SkillCatalogEntry => !!s);
  if (skills.length) {
    parts.push(
      `Active skills for this chat (follow their instructions):\n${skills
        .map((s) => {
          const full = s as SkillRecord;
          const body =
            'instructions' in full && full.instructions
              ? full.instructions.slice(0, 6000)
              : s.description;
          return `### /${s.name}\n${body}`;
        })
        .join('\n\n')}`
    );
  }
  return parts;
}

export function connectorsWarningCount(state: ComposerToolsState): number {
  // Mirror Claude’s “needs attention” badge when any popular connector is off
  // or Granola-style unavailable is present — use disabled available connectors.
  return CONNECTOR_CATALOG.filter((c) => c.available !== false && state.connectors[c.id] === false)
    .length;
}
