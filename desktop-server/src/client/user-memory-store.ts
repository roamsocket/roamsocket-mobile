/**
 * User (profile) memory — structured entries for Settings → Memory.
 *
 * Mirrors Claude-style memory: You / Topics / Areas, freeform add/edit,
 * detail view, and import paste from another AI provider.
 * Stored in localStorage only (device-private).
 */
import type { StorageLike } from "./history-store.js";

const KEY = "apc.userMemory.v1";
const ACTIVITY_KEY = "apc.userMemory.activity.v1";
const ACTIVITY_MAX_AGE_MS = 60 * 60 * 24 * 30 * 1000; // 30 days
const ACTIVITY_MAX_COUNT = 200;

export type MemoryCategory = "you" | "topic" | "area";

export interface MemoryEntry {
  id: string;
  category: MemoryCategory;
  /** Short label, e.g. "Profile", "Gaming", "Kind365". */
  title: string;
  /** One-line blurb shown in the list. */
  summary: string;
  /** Bullet details shown on the detail screen. */
  details: string[];
  updatedAt: number;
}

export interface UserMemoryState {
  entries: MemoryEntry[];
}

/** Structured chat-driven action parsed from a `<memory>` tag. */
export type MemoryParsedAction =
  | {
      kind: "add";
      category: MemoryCategory;
      title: string;
      summary: string;
      details: string[];
    }
  | { kind: "forget"; target: string }
  | { kind: "rename"; target: string; value: string }
  | { kind: "set_summary"; target: string; value: string }
  | { kind: "set_details"; target: string; value: string[] };

/** A single mutation recorded so the user can review and undo it. */
export interface MemoryActivityEntry {
  id: string;
  timestamp: number;
  kind: "add" | "update" | "forget" | "rename";
  entryID: string;
  entryTitle: string;
  detailPreview: string;
  before: MemoryEntry | null;
  after: MemoryEntry | null;
  source: "chat" | "user";
}

export const MEMORY_CATEGORY_LABELS: Record<MemoryCategory, string> = {
  you: "You",
  topic: "Topics",
  area: "Areas",
};

export const MEMORY_CATEGORY_ORDER: MemoryCategory[] = ["you", "topic", "area"];

/** Prompt users copy into another AI product when importing memory. */
export const MEMORY_IMPORT_PROMPT = `Export all of my stored memories and any context you've learned about me from past conversations. Preserve my words verbatim where possible, especially for instructions and preferences.

## Categories (output in this order):

### You — Profile
- Summary line
- Bullet details (name, role, location, preferences)

### Topics
One section per interest/topic with a short summary and bullets.

### Areas
One section per project/product/domain with a short summary and bullets.`;

function uid(): string {
  return `mem_${Math.random().toString(36).slice(2, 10)}`;
}

function normalizeEntry(raw: Partial<MemoryEntry> & { id: string; title: string }): MemoryEntry {
  const cat = raw.category;
  const category: MemoryCategory =
    cat === "topic" || cat === "area" || cat === "you" ? cat : "you";
  return {
    id: raw.id,
    category,
    title: (raw.title || "Untitled").trim() || "Untitled",
    summary: (raw.summary ?? "").trim(),
    details: Array.isArray(raw.details)
      ? raw.details.map((d) => String(d).trim()).filter(Boolean)
      : [],
    updatedAt: typeof raw.updatedAt === "number" ? raw.updatedAt : Date.now(),
  };
}

function normalizeActivity(raw: Partial<MemoryActivityEntry> & { id: string; timestamp: number }): MemoryActivityEntry {
  return {
    id: raw.id,
    timestamp: raw.timestamp,
    kind:
      raw.kind === "add" || raw.kind === "update" || raw.kind === "forget" || raw.kind === "rename"
        ? raw.kind
        : "update",
    entryID: raw.entryID ?? "",
    entryTitle: raw.entryTitle ?? "",
    detailPreview: raw.detailPreview ?? "",
    before: raw.before ?? null,
    after: raw.after ?? null,
    source: raw.source === "user" ? "user" : "chat",
  };
}

function mergeDetails(existing: string[], adding: string[]): string[] {
  const out = [...existing];
  for (const d of adding) {
    if (!out.some((e) => e.toLowerCase() === d.toLowerCase())) out.push(d);
  }
  return out;
}

export class UserMemoryStore {
  private entries: MemoryEntry[] = [];
  private activity: MemoryActivityEntry[] = [];

  constructor(private storage: StorageLike) {
    this.load();
    this.pruneActivity();
  }

  load(): void {
    try {
      const raw = this.storage.getItem(KEY);
      if (!raw) {
        this.entries = [];
      } else {
        const parsed = JSON.parse(raw) as { entries?: Partial<MemoryEntry>[] };
        this.entries = Array.isArray(parsed.entries)
          ? parsed.entries
              .filter((e): e is Partial<MemoryEntry> & { id: string; title: string } =>
                !!e && typeof e.id === "string" && typeof e.title === "string",
              )
              .map(normalizeEntry)
          : [];
      }
    } catch {
      this.entries = [];
    }
    try {
      const raw = this.storage.getItem(ACTIVITY_KEY);
      if (raw) {
        const parsed = JSON.parse(raw) as { activity?: Partial<MemoryActivityEntry>[] };
        this.activity = Array.isArray(parsed.activity)
          ? parsed.activity
              .filter((a): a is Partial<MemoryActivityEntry> & { id: string; timestamp: number } =>
                !!a && typeof a.id === "string" && typeof a.timestamp === "number",
              )
              .map(normalizeActivity)
          : [];
      }
    } catch {
      this.activity = [];
    }
  }

  persist(): void {
    this.storage.setItem(KEY, JSON.stringify({ entries: this.entries }));
  }

  persistActivity(): void {
    this.storage.setItem(ACTIVITY_KEY, JSON.stringify({ activity: this.activity }));
  }

  list(): MemoryEntry[] {
    return [...this.entries].sort((a, b) => b.updatedAt - a.updatedAt);
  }

  get(id: string): MemoryEntry | undefined {
    return this.entries.find((e) => e.id === id);
  }

  byCategory(category: MemoryCategory): MemoryEntry[] {
    return this.list().filter((e) => e.category === category);
  }

  upsert(entry: Omit<MemoryEntry, "id" | "updatedAt"> & { id?: string }): MemoryEntry {
    const now = Date.now();
    if (entry.id) {
      const existing = this.get(entry.id);
      if (existing) {
        existing.category = entry.category;
        existing.title = entry.title.trim() || existing.title;
        existing.summary = entry.summary.trim();
        existing.details = entry.details.map((d) => d.trim()).filter(Boolean);
        existing.updatedAt = now;
        this.persist();
        return existing;
      }
    }
    const created = normalizeEntry({
      id: entry.id ?? uid(),
      category: entry.category,
      title: entry.title,
      summary: entry.summary,
      details: entry.details,
      updatedAt: now,
    });
    this.entries.unshift(created);
    this.persist();
    return created;
  }

  delete(id: string): void {
    this.entries = this.entries.filter((e) => e.id !== id);
    this.persist();
  }

  /**
   * Freeform fact at the Memory root input (e.g. "My dog's name is Beans").
   * Appends to Profile under You, creating it when needed.
   */
  addFreeformFact(text: string): MemoryEntry | null {
    const fact = text.trim();
    if (!fact) return null;
    const bullet = fact.charAt(0).toUpperCase() + fact.slice(1);
    let profile = this.byCategory("you").find(
      (e) => e.title.toLowerCase() === "profile",
    );
    if (!profile) {
      profile = this.upsert({
        category: "you",
        title: "Profile",
        summary: bullet.length > 80 ? `${bullet.slice(0, 77)}…` : bullet,
        details: [bullet],
      });
      return profile;
    }
    if (!profile.details.some((d) => d.toLowerCase() === bullet.toLowerCase())) {
      profile.details = [...profile.details, bullet];
    }
    if (!profile.summary.trim()) {
      profile.summary = bullet.length > 80 ? `${bullet.slice(0, 77)}…` : bullet;
    }
    profile.updatedAt = Date.now();
    this.persist();
    return profile;
  }

  /**
   * Natural-language edit for a single entry (detail screen).
   * "forget X" / "remove X" drops matching bullets; otherwise appends a note.
   */
  applyEntryCommand(id: string, command: string): MemoryEntry | null {
    const entry = this.get(id);
    if (!entry) return null;
    const cmd = command.trim();
    if (!cmd) return entry;
    const lower = cmd.toLowerCase();

    if (
      lower.startsWith("forget ") ||
      lower.startsWith("remove ") ||
      lower.startsWith("delete ")
    ) {
      const topic = cmd.replace(/^(forget|remove|delete)\s+/i, "").trim();
      if (topic) {
        const nextDetails = entry.details.filter(
          (d) => !d.toLowerCase().includes(topic.toLowerCase()),
        );
        if (nextDetails.length !== entry.details.length) {
          entry.details = nextDetails;
        } else {
          entry.details = [
            ...entry.details,
            `Note: user asked to forget “${topic}”.`,
          ];
        }
        if (entry.summary.toLowerCase().includes(topic.toLowerCase())) {
          entry.summary = nextDetails[0] ?? entry.summary;
        }
      }
    } else if (/^change summary to\s+/i.test(cmd) || /^set summary to\s+/i.test(cmd)) {
      entry.summary = cmd.replace(/^(change|set) summary to\s+/i, "").trim();
    } else if (/^rename to\s+/i.test(cmd)) {
      entry.title = cmd.replace(/^rename to\s+/i, "").trim() || entry.title;
    } else {
      const fact = cmd
        .replace(/^remember that(?: i)?\s+/i, "")
        .replace(/^remember\s+/i, "")
        .replace(/^add\s+/i, "")
        .trim();
      const bullet = fact.charAt(0).toUpperCase() + fact.slice(1);
      if (!bullet) {
        // nothing to do
      } else if (entry.details.length <= 1) {
        // Smart: with a single fact, freeform text replaces it (matches
        // "tell the assistant what to change" intent). With multiple facts,
        // append.
        entry.details = [bullet];
        if (!entry.summary || entry.summary.toLowerCase() !== bullet.toLowerCase()) {
          entry.summary = bullet.length > 80 ? `${bullet.slice(0, 77)}…` : bullet;
        }
      } else if (!entry.details.some((d) => d.toLowerCase() === bullet.toLowerCase())) {
        entry.details = [...entry.details, bullet];
      }
    }
    entry.updatedAt = Date.now();
    this.persist();
    return entry;
  }

  // MARK: - Activity log (auto-save from chat)

  /**
   * Apply a structured action parsed from a chat reply. Returns the affected
   * entry, or null when the action was a no-op.
   */
  applyAction(action: MemoryParsedAction): MemoryEntry | null {
    switch (action.kind) {
      case "add":
        return this.applyAddAction(action);
      case "forget":
        return this.applyForgetAction(action.target);
      case "rename":
        return this.applyRenameAction(action.target, action.value);
      case "set_summary":
        return this.applySetSummaryAction(action.target, action.value);
      case "set_details":
        return this.applySetDetailsAction(action.target, action.value);
    }
  }

  /** Recent activity rows, newest first. */
  activityList(opts?: { source?: "chat" | "user"; limit?: number }): MemoryActivityEntry[] {
    const source = opts?.source;
    const limit = opts?.limit ?? 50;
    const pool = source ? this.activity.filter((a) => a.source === source) : this.activity;
    return [...pool].sort((a, b) => b.timestamp - a.timestamp).slice(0, limit);
  }

  /** Undo a single activity row. Returns true on success. */
  undoActivity(id: string): boolean {
    const idx = this.activity.findIndex((a) => a.id === id);
    if (idx < 0) return false;
    const row = this.activity[idx]!;
    // For every kind, restoring the entry means putting back the `before`
    // snapshot (the pre-mutation state). For `add`, there is no `before`,
    // so the entry is removed entirely.
    if (row.before) {
      const eidx = this.entries.findIndex((e) => e.id === row.before!.id);
      if (eidx >= 0) this.entries[eidx] = row.before;
      else this.entries.unshift(row.before);
    } else {
      this.entries = this.entries.filter((e) => e.id !== row.entryID);
    }
    this.activity.splice(idx, 1);
    this.persist();
    this.persistActivity();
    return true;
  }

  private recordActivity(row: Omit<MemoryActivityEntry, "id" | "timestamp">): void {
    const full: MemoryActivityEntry = {
      id: `act_${Math.random().toString(36).slice(2, 10)}`,
      timestamp: Date.now(),
      ...row,
    };
    this.activity.push(full);
    if (this.activity.length > ACTIVITY_MAX_COUNT) {
      this.activity = this.activity.slice(-ACTIVITY_MAX_COUNT);
    }
    this.persistActivity();
  }

  private pruneActivity(): void {
    const cutoff = Date.now() - ACTIVITY_MAX_AGE_MS;
    const kept = this.activity.filter((a) => a.timestamp >= cutoff);
    const trimmed = kept.length > ACTIVITY_MAX_COUNT ? kept.slice(-ACTIVITY_MAX_COUNT) : kept;
    if (trimmed.length !== this.activity.length) {
      this.activity = trimmed;
      this.persistActivity();
    }
  }

  private findByTitleOrContains(needle: string): MemoryEntry | undefined {
    const lower = needle.toLowerCase();
    const exact = this.entries.find((e) => e.title.toLowerCase() === lower);
    if (exact) return exact;
    return this.entries.find((e) => e.details.some((d) => d.toLowerCase().includes(lower)))
      ?? this.entries.find((e) => e.summary.toLowerCase().includes(lower));
  }

  private applyAddAction(
    action: Extract<MemoryParsedAction, { kind: "add" }>,
  ): MemoryEntry | null {
    const lower = action.title.toLowerCase();
    const existing = this.entries.find(
      (e) => e.category === action.category && e.title.toLowerCase() === lower,
    );
    if (existing) {
      const before = { ...existing };
      const cleaned = action.details.map((d) => d.trim()).filter(Boolean);
      const merged = mergeDetails(existing.details, cleaned);
      const newSummary = action.summary.trim();
      if (
        merged.length === existing.details.length &&
        (newSummary === "" || newSummary === existing.summary)
      ) {
        return null;
      }
      existing.details = merged;
      if (newSummary) existing.summary = newSummary;
      existing.updatedAt = Date.now();
      this.persist();
      this.recordActivity({
        kind: "update",
        entryID: existing.id,
        entryTitle: existing.title,
        detailPreview: newSummary || cleaned[0] || existing.summary,
        before,
        after: { ...existing },
        source: "chat",
      });
      return existing;
    }
    const created = this.upsert({
      category: action.category,
      title: action.title,
      summary: action.summary,
      details: action.details,
    });
    this.recordActivity({
      kind: "add",
      entryID: created.id,
      entryTitle: created.title,
      detailPreview: created.summary || created.details[0] || created.title,
      before: null,
      after: { ...created },
      source: "chat",
    });
    return created;
  }

  private applyForgetAction(target: string): MemoryEntry | null {
    const victim = this.findByTitleOrContains(target);
    if (!victim) return null;
    const before = { ...victim };
    const next = victim.details.filter((d) => !d.toLowerCase().includes(target.toLowerCase()));
    if (next.length === victim.details.length) return null;
    const after = { ...victim, details: next, updatedAt: Date.now() };
    const eidx = this.entries.findIndex((e) => e.id === victim.id);
    if (eidx >= 0) this.entries[eidx] = after;
    this.persist();
    this.recordActivity({
      kind: "forget",
      entryID: victim.id,
      entryTitle: victim.title,
      detailPreview: target,
      before,
      after,
      source: "chat",
    });
    return after;
  }

  private applyRenameAction(target: string, value: string): MemoryEntry | null {
    const trimmed = value.trim();
    if (!trimmed) return null;
    const victim = this.findByTitleOrContains(target);
    if (!victim) return null;
    const before = { ...victim };
    const after = { ...victim, title: trimmed, updatedAt: Date.now() };
    const eidx = this.entries.findIndex((e) => e.id === victim.id);
    if (eidx >= 0) this.entries[eidx] = after;
    this.persist();
    this.recordActivity({
      kind: "rename",
      entryID: victim.id,
      entryTitle: trimmed,
      detailPreview: trimmed,
      before,
      after,
      source: "chat",
    });
    return after;
  }

  private applySetSummaryAction(target: string, value: string): MemoryEntry | null {
    const victim = this.findByTitleOrContains(target);
    if (!victim) return null;
    const trimmed = value.trim();
    if (!trimmed || trimmed === victim.summary) return null;
    const before = { ...victim };
    const after = { ...victim, summary: trimmed, updatedAt: Date.now() };
    const eidx = this.entries.findIndex((e) => e.id === victim.id);
    if (eidx >= 0) this.entries[eidx] = after;
    this.persist();
    this.recordActivity({
      kind: "update",
      entryID: victim.id,
      entryTitle: victim.title,
      detailPreview: trimmed,
      before,
      after,
      source: "chat",
    });
    return after;
  }

  private applySetDetailsAction(target: string, value: string[]): MemoryEntry | null {
    const victim = this.findByTitleOrContains(target);
    if (!victim) return null;
    const cleaned = value.map((d) => d.trim()).filter(Boolean);
    if (cleaned.length === 0) return null;
    const before = { ...victim };
    const after = { ...victim, details: cleaned, updatedAt: Date.now() };
    const eidx = this.entries.findIndex((e) => e.id === victim.id);
    if (eidx >= 0) this.entries[eidx] = after;
    this.persist();
    this.recordActivity({
      kind: "update",
      entryID: victim.id,
      entryTitle: victim.title,
      detailPreview: cleaned[0] ?? victim.title,
      before,
      after,
      source: "chat",
    });
    return after;
  }

  /**
   * Parse pasted export from another AI into structured entries.
   * Best-effort markdown headings; falls back to one Imported note.
   */
  importFromText(raw: string): number {
    const text = raw.replace(/\r\n/g, "\n").trim();
    if (!text) return 0;

    const blocks = splitImportBlocks(text);
    if (blocks.length === 0) {
      this.upsert({
        category: "you",
        title: "Imported",
        summary: text.slice(0, 100).replace(/\n/g, " "),
        details: text
          .split(/\n+/)
          .map((l) => l.replace(/^[-*•]\s*/, "").trim())
          .filter(Boolean)
          .slice(0, 40),
      });
      return 1;
    }

    let count = 0;
    for (const block of blocks) {
      this.upsert({
        category: block.category,
        title: block.title,
        summary: block.summary,
        details: block.details,
      });
      count += 1;
    }
    return count;
  }

  /** System prompt blob for chat injection. */
  formatForSystem(): string {
    const parts: string[] = [];
    for (const cat of MEMORY_CATEGORY_ORDER) {
      const items = this.byCategory(cat);
      if (items.length === 0) continue;
      parts.push(`## ${MEMORY_CATEGORY_LABELS[cat]}`);
      for (const e of items) {
        parts.push(`### ${e.title}`);
        if (e.summary) parts.push(e.summary);
        for (const d of e.details) {
          parts.push(`- ${d}`);
        }
      }
    }
    return parts.join("\n");
  }

  isEmpty(): boolean {
    return this.entries.length === 0;
  }
}

interface ImportBlock {
  category: MemoryCategory;
  title: string;
  summary: string;
  details: string[];
}

function splitImportBlocks(text: string): ImportBlock[] {
  const lines = text.split("\n");
  const blocks: ImportBlock[] = [];
  let category: MemoryCategory = "you";
  let title = "";
  let summary = "";
  let details: string[] = [];
  let sawHeading = false;

  const flush = () => {
    if (!title && details.length === 0 && !summary) return;
    blocks.push({
      category,
      title: title || (category === "you" ? "Profile" : "Untitled"),
      summary: summary || details[0] || "",
      details: details.length ? details : summary ? [summary] : [],
    });
    title = "";
    summary = "";
    details = [];
  };

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) continue;

    // Category headers: "## You", "### Topics", "You — Profile", etc.
    const catMatch = line.match(
      /^(?:#{1,3}\s*)?(You|Topics?|Areas?)\b(?:\s*[—–:-]\s*(.+))?$/i,
    );
    if (catMatch) {
      flush();
      sawHeading = true;
      const label = catMatch[1]!.toLowerCase();
      if (label.startsWith("topic")) category = "topic";
      else if (label.startsWith("area")) category = "area";
      else category = "you";
      const rest = (catMatch[2] ?? "").trim();
      if (rest) {
        title = rest;
      } else if (category === "you") {
        title = "Profile";
      }
      continue;
    }

    // Generic ### Title heading
    const hMatch = line.match(/^#{1,3}\s+(.+)$/);
    if (hMatch) {
      flush();
      sawHeading = true;
      title = hMatch[1]!.trim();
      // Infer category from keywords if still default
      if (category === "you" && !/profile|about me|who i am/i.test(title)) {
        if (/app|project|product|startup|company|kind|work/i.test(title)) {
          category = "area";
        } else if (!/name|role|location|bio/i.test(title)) {
          category = "topic";
        }
      }
      continue;
    }

    const bullet = line.replace(/^[-*•]\s+/, "").replace(/^\d+\.\s+/, "");
    if (bullet !== line || line.startsWith("-") || line.startsWith("*") || line.startsWith("•")) {
      details.push(bullet.trim());
      continue;
    }

    if (!summary) {
      summary = line;
    } else {
      details.push(line);
    }
  }

  flush();
  return sawHeading ? blocks : [];
}

export function relativeMemoryTime(ts: number, now = Date.now()): string {
  const diff = Math.max(0, now - ts);
  const min = Math.floor(diff / 60_000);
  if (min < 1) return "just now";
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 48) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 14) return `${day}d ago`;
  return new Date(ts).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}
