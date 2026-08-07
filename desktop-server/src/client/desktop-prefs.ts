/**
 * Desktop UI prefs (memory, default effort) — localStorage, not secrets.
 */
import type { StorageLike } from "./history-store.js";
import type { Effort } from "./providers-meta.js";

const KEY = "apc.desktopPrefs.v1";

export interface DesktopUiPrefs {
  /** Search past chats for relevant context. */
  memorySearchChats: boolean;
  /** Auto-generate lasting memory from chats. */
  memoryGenerateFromChats: boolean;
  /** Default reasoning effort for chat/code. */
  defaultEffort: Effort;
}

const DEFAULTS: DesktopUiPrefs = {
  memorySearchChats: true,
  memoryGenerateFromChats: true,
  defaultEffort: "high",
};

export const EFFORT_GUIDE: Record<
  Effort,
  { label: string; summary: string; detail: string }
> = {
  low: {
    label: "Low",
    summary: "Faster replies",
    detail:
      "Minimal deliberation. Best for quick questions, simple edits, and when latency matters more than depth.",
  },
  medium: {
    label: "Medium",
    summary: "Balanced",
    detail:
      "Solid default for everyday coding and chat. Weighs trade-offs without spending a long time planning.",
  },
  high: {
    label: "High",
    summary: "Thorough reasoning",
    detail:
      "More careful multi-step reasoning. Prefer for hard bugs, architecture, refactors, and tasks with many tools.",
  },
};

export function loadDesktopUiPrefs(storage: StorageLike): DesktopUiPrefs {
  try {
    const raw = storage.getItem(KEY);
    if (!raw) return { ...DEFAULTS };
    const parsed = JSON.parse(raw) as Partial<DesktopUiPrefs>;
    return {
      memorySearchChats: parsed.memorySearchChats ?? DEFAULTS.memorySearchChats,
      memoryGenerateFromChats:
        parsed.memoryGenerateFromChats ?? DEFAULTS.memoryGenerateFromChats,
      defaultEffort:
        parsed.defaultEffort === "low" ||
        parsed.defaultEffort === "medium" ||
        parsed.defaultEffort === "high"
          ? parsed.defaultEffort
          : DEFAULTS.defaultEffort,
    };
  } catch {
    return { ...DEFAULTS };
  }
}

export function saveDesktopUiPrefs(storage: StorageLike, prefs: DesktopUiPrefs): void {
  storage.setItem(KEY, JSON.stringify(prefs));
}
