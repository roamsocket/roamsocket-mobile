/**
 * Lightweight Tasks preferences — short helper generations
 * (titles, artifact names, commit subjects, thinking summaries).
 */
import type { StorageLike } from "./history-store.js";

const KEY = "apc.lightweightTasks.v1";

export type LightweightMode = "appleFoundation" | "linkedModel";

export interface LightweightTasksPrefs {
  mode: LightweightMode;
  linkedProvider: string | null;
  linkedModel: string | null;
  /** First-launch walkthrough finished. */
  walkthroughCompleted: boolean;
}

const DEFAULTS: LightweightTasksPrefs = {
  mode: "linkedModel",
  linkedProvider: null,
  linkedModel: null,
  walkthroughCompleted: false,
};

export function loadLightweightPrefs(storage: StorageLike): LightweightTasksPrefs {
  try {
    const raw = storage.getItem(KEY);
    if (!raw) return { ...DEFAULTS };
    const parsed = JSON.parse(raw) as Partial<LightweightTasksPrefs>;
    return {
      mode:
        parsed.mode === "appleFoundation" || parsed.mode === "linkedModel"
          ? parsed.mode
          : DEFAULTS.mode,
      linkedProvider: parsed.linkedProvider ?? null,
      linkedModel: parsed.linkedModel ?? null,
      walkthroughCompleted: !!parsed.walkthroughCompleted,
    };
  } catch {
    return { ...DEFAULTS };
  }
}

export function saveLightweightPrefs(
  storage: StorageLike,
  prefs: LightweightTasksPrefs,
): void {
  storage.setItem(KEY, JSON.stringify(prefs));
}

export function lightweightModeLabel(mode: LightweightMode): string {
  return mode === "appleFoundation" ? "Apple Intelligence" : "Linked model";
}
