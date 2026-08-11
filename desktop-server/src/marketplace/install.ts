/**
 * Marketplace install helpers — map catalog listings into local skill records.
 * Pure functions that take a `SkillsStore`-like object so they're testable
 * without a real localStorage.
 */
import type { SkillRecord } from "../client/skills-store.js";
import type { MarketplaceCatalog, MarketplacePlugin, MarketplaceSkill } from "./types.js";

/** Minimal subset of SkillsStore needed for install — enables unit testing. */
export interface InstallTarget {
  get(id: string): SkillRecord | undefined;
  create(input: { name: string; description: string; instructions: string }): SkillRecord;
}

/**
 * Build the skill body for a marketplace skill.
 * Uses the catalog `instructions` field when present; otherwise synthesises a
 * minimal markdown body from the name + description.
 */
export function skillInstructionsFor(skill: MarketplaceSkill): string {
  if (skill.instructions && skill.instructions.trim()) {
    return skill.instructions;
  }
  return `# ${skill.name}\n\n${skill.description}\n`;
}

/** True when a skill with this id is already in the store (builtin or custom). */
export function isMarketplaceSkillInstalled(store: InstallTarget, skillId: string): boolean {
  return store.get(skillId) !== undefined;
}

/**
 * Install a single marketplace skill into the local skills store.
 * Throws if the skill is already installed (call `isMarketplaceSkillInstalled` first).
 */
export function installMarketplaceSkill(
  store: InstallTarget,
  skill: MarketplaceSkill,
): SkillRecord {
  if (isMarketplaceSkillInstalled(store, skill.id)) {
    throw new Error(`Skill “${skill.name}” is already installed.`);
  }
  return store.create({
    name: skill.name,
    description: skill.description,
    instructions: skillInstructionsFor(skill),
  });
}

export interface PluginInstallResult {
  installed: number;
  skipped: number;
  missing: number;
  errors: string[];
}

/**
 * Install every skill referenced by a plugin's `skillIds`.
 * Skills that are already installed or missing from the catalog are skipped.
 */
export function installMarketplacePlugin(
  store: InstallTarget,
  plugin: MarketplacePlugin,
  catalog: MarketplaceCatalog,
): PluginInstallResult {
  const result: PluginInstallResult = { installed: 0, skipped: 0, missing: 0, errors: [] };
  const ids = plugin.skillIds ?? [];
  for (const id of ids) {
    const skill = catalog.skills.find((s) => s.id === id);
    if (!skill) {
      result.missing++;
      continue;
    }
    if (isMarketplaceSkillInstalled(store, skill.id)) {
      result.skipped++;
      continue;
    }
    try {
      installMarketplaceSkill(store, skill);
      result.installed++;
    } catch (err) {
      result.errors.push(String((err as Error).message ?? err));
      result.skipped++;
    }
  }
  return result;
}

/**
 * Resolve the list of catalog skills that a plugin would install,
 * partitioned into `available` (in catalog) and `missing` (id not found).
 */
export function resolvePluginSkills(
  plugin: MarketplacePlugin,
  catalog: MarketplaceCatalog,
): { available: MarketplaceSkill[]; missing: string[] } {
  const available: MarketplaceSkill[] = [];
  const missing: string[] = [];
  for (const id of plugin.skillIds ?? []) {
    const skill = catalog.skills.find((s) => s.id === id);
    if (skill) {
      available.push(skill);
    } else {
      missing.push(id);
    }
  }
  return { available, missing };
}
