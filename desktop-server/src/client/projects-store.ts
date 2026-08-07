/**
 * Projects + per-project instructions / memory (desktop).
 */
import type { StorageLike } from "./history-store.js";

export type ProjectContextKind =
  | "file"
  | "text"
  | "url"
  | "github"
  | "figma"
  | "drive"
  | "godaddy"
  | "artifact"
  | "other";

export interface ProjectContextItem {
  id: string;
  kind: ProjectContextKind;
  title: string;
  /** Snippet or full text content for chat injection */
  content: string;
  /** Optional remote / file path reference */
  ref?: string;
  createdAt: number;
}

export interface ProjectItem {
  id: string;
  name: string;
  /** Short blurb shown on project cards */
  description: string;
  /** Project instructions injected into chats (Set project instructions modal) */
  instructions: string;
  /** Project memory narrative (Manage project memory) */
  memory: string;
  memoryUpdatedAt: number | null;
  /** Reference docs / files for this project (Context rail) */
  contextItems: ProjectContextItem[];
  createdAt: number;
  updatedAt: number;
}

const KEY = "apc.projects.v1";

function uid(): string {
  return `proj_${Math.random().toString(36).slice(2, 10)}`;
}

function normalize(p: Partial<ProjectItem> & { id: string; name: string }): ProjectItem {
  const now = Date.now();
  return {
    id: p.id,
    name: p.name,
    description: p.description ?? "",
    instructions: p.instructions ?? "",
    memory: p.memory ?? "",
    memoryUpdatedAt: p.memoryUpdatedAt ?? null,
    contextItems: Array.isArray(p.contextItems) ? p.contextItems : [],
    createdAt: p.createdAt ?? now,
    updatedAt: p.updatedAt ?? now,
  };
}

export class ProjectsStore {
  private projects: ProjectItem[] = [];

  constructor(private storage: StorageLike) {
    this.load();
  }

  load(): void {
    try {
      const raw = this.storage.getItem(KEY);
      if (!raw) {
        this.projects = [];
        return;
      }
      const parsed = JSON.parse(raw) as { projects?: Partial<ProjectItem>[] };
      this.projects = Array.isArray(parsed.projects)
        ? parsed.projects
            .filter((p): p is Partial<ProjectItem> & { id: string; name: string } =>
              !!p && typeof p.id === "string" && typeof p.name === "string",
            )
            .map(normalize)
        : [];
    } catch {
      this.projects = [];
    }
  }

  persist(): void {
    this.storage.setItem(KEY, JSON.stringify({ projects: this.projects }));
  }

  list(): ProjectItem[] {
    return [...this.projects].sort((a, b) => b.updatedAt - a.updatedAt);
  }

  get(id: string): ProjectItem | undefined {
    return this.projects.find((p) => p.id === id);
  }

  create(name: string, description = ""): ProjectItem {
    const now = Date.now();
    const item = normalize({
      id: uid(),
      name: name.trim() || "Untitled project",
      description: description.trim(),
      createdAt: now,
      updatedAt: now,
    });
    this.projects.unshift(item);
    this.persist();
    return item;
  }

  rename(id: string, name: string): void {
    const p = this.get(id);
    if (!p) return;
    p.name = name.trim() || p.name;
    p.updatedAt = Date.now();
    this.persist();
  }

  setDescription(id: string, description: string): void {
    const p = this.get(id);
    if (!p) return;
    p.description = description.trim();
    p.updatedAt = Date.now();
    this.persist();
  }

  setInstructions(id: string, instructions: string): void {
    const p = this.get(id);
    if (!p) return;
    p.instructions = instructions.trim();
    p.updatedAt = Date.now();
    this.persist();
  }

  setMemory(id: string, memory: string): void {
    const p = this.get(id);
    if (!p) return;
    p.memory = memory.trim();
    p.memoryUpdatedAt = Date.now();
    p.updatedAt = Date.now();
    this.persist();
  }

  addContextItem(
    projectId: string,
    item: Omit<ProjectContextItem, "id" | "createdAt"> & { id?: string; createdAt?: number },
  ): ProjectContextItem | null {
    const p = this.get(projectId);
    if (!p) return null;
    const entry: ProjectContextItem = {
      id: item.id ?? uid(),
      kind: item.kind,
      title: item.title.trim() || "Untitled",
      content: item.content,
      ref: item.ref,
      createdAt: item.createdAt ?? Date.now(),
    };
    p.contextItems = [entry, ...p.contextItems];
    p.updatedAt = Date.now();
    this.persist();
    return entry;
  }

  removeContextItem(projectId: string, itemId: string): void {
    const p = this.get(projectId);
    if (!p) return;
    p.contextItems = p.contextItems.filter((c) => c.id !== itemId);
    p.updatedAt = Date.now();
    this.persist();
  }

  /**
   * Apply a natural-language memory edit:
   * - "forget …" removes matching lines / appends a forget note
   * - "remember …" / "remember that I …" appends a memory bullet
   * - otherwise appends the adjustment as a note
   */
  applyMemoryCommand(id: string, command: string): string {
    const p = this.get(id);
    if (!p) return "";
    const cmd = command.trim();
    if (!cmd) return p.memory;

    let next = p.memory;
    const lower = cmd.toLowerCase();

    if (lower.startsWith("forget ")) {
      const topic = cmd.slice(7).trim().replace(/^\*|\*$/g, "");
      if (topic) {
        const lines = next.split(/\n/).filter((line) => !line.toLowerCase().includes(topic.toLowerCase()));
        next = lines.join("\n").trim();
        if (next === p.memory.trim()) {
          next = (next ? next + "\n\n" : "") + `Note: user asked to forget “${topic}”.`;
        }
      }
    } else if (/^remember that i\s+/i.test(cmd) || /^remember that\s+/i.test(cmd)) {
      const fact = cmd.replace(/^remember that(?: i)?\s+/i, "").trim();
      if (fact) {
        next = (next ? next + "\n\n" : "") + `• ${fact.charAt(0).toUpperCase()}${fact.slice(1)}`;
      }
    } else if (lower.startsWith("remember ")) {
      const fact = cmd.slice(9).trim();
      if (fact) {
        next = (next ? next + "\n\n" : "") + `• ${fact.charAt(0).toUpperCase()}${fact.slice(1)}`;
      }
    } else if (lower.startsWith("don't ") || lower.startsWith("dont ") || lower.startsWith("do not ")) {
      next = (next ? next + "\n\n" : "") + `• Preference: ${cmd}`;
    } else {
      next = (next ? next + "\n\n" : "") + `• ${cmd}`;
    }

    this.setMemory(id, next);
    return next;
  }

  touch(id: string): void {
    const p = this.get(id);
    if (!p) return;
    p.updatedAt = Date.now();
    this.persist();
  }

  delete(id: string): void {
    this.projects = this.projects.filter((p) => p.id !== id);
    this.persist();
  }
}

/**
 * Empty-state copy shown in the Manage memory contenteditable (UI chrome only).
 * Must never be persisted as real project memory.
 */
export const MEMORY_EMPTY_STATE_MARKER = "No project memory yet";

/**
 * Turn contenteditable innerText into persistable memory.
 * Drops empty-state chrome when the editor started empty / still looks like chrome.
 */
export function memoryTextFromEditor(
  innerText: string,
  opts?: { startedEmpty?: boolean; userEdited?: boolean },
): string {
  const t = (innerText ?? "").replace(/\u00a0/g, " ").trim();
  if (!t) return "";
  if (isMemoryEmptyStateChrome(t)) {
    // Unedited chrome or residual chrome alone → empty
    if (opts?.startedEmpty !== false && !opts?.userEdited) return "";
    // Even if "edited", pure chrome strings must never be stored
    return "";
  }
  return t;
}

/** True when text is (or is only) the Manage-memory empty-state UI. */
export function isMemoryEmptyStateChrome(text: string): boolean {
  const n = text.replace(/\s+/g, " ").trim();
  if (!n) return false;
  if (!n.toLowerCase().includes(MEMORY_EMPTY_STATE_MARKER.toLowerCase())) {
    return false;
  }
  // Strip known chrome pieces; leftover punctuation/whitespace does not count as real memory
  const withoutChrome = n
    .replace(/Purpose\s*&\s*context/gi, " ")
    .replace(new RegExp(MEMORY_EMPTY_STATE_MARKER.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi"), " ")
    .replace(
      /Use the box below to add facts,?\s*or chat in this project and generate memory later\.?/gi,
      " ",
    )
    .replace(/[\s.·•,;:]+/g, " ")
    .trim();
  return withoutChrome.length === 0;
}

/** Cycling placeholders for the project memory adjust field. */
export const MEMORY_EDIT_PLACEHOLDERS = [
  "Tell us what to adjust in our memory",
  "forget *example*",
  "remember that I *example*",
  "remember that I prefer concise answers",
  "forget my old job title",
  "Don't bring up my former baseball career…",
  "remember that I work on kind365",
  "forget confidential client names",
] as const;

export function memoryPlaceholderAt(index: number): string {
  const i = ((index % MEMORY_EDIT_PLACEHOLDERS.length) + MEMORY_EDIT_PLACEHOLDERS.length) %
    MEMORY_EDIT_PLACEHOLDERS.length;
  return MEMORY_EDIT_PLACEHOLDERS[i]!;
}
