import type { StorageLike } from "./history-store.js";

export interface ArtifactItem {
  id: string;
  title: string;
  content: string;
  language?: string;
  sourceChatId?: string;
  /** Assistant message that produced this artifact (for scroll-to in chat). */
  sourceMessageId?: string;
  createdAt: number;
}

const KEY = "apc.artifacts.v1";
/** Capture long assistant replies / fenced code as artifacts (≥ 10 lines or has ```). */
const MIN_LINES = 10;

function uid(): string {
  return `art_${Math.random().toString(36).slice(2, 10)}`;
}

export function shouldCaptureAsArtifact(content: string): boolean {
  const trimmed = content.trim();
  if (!trimmed) return false;
  if (trimmed.includes("```")) return true;
  return trimmed.split(/\r?\n/).length >= MIN_LINES;
}

export function titleFromContent(content: string): string {
  const fence = content.match(/```(\w+)?\n([\s\S]*?)```/);
  if (fence) {
    const lang = fence[1] ? `${fence[1]} ` : "";
    const first = (fence[2] ?? "").trim().split(/\r?\n/)[0] ?? "";
    const snippet = first.slice(0, 40);
    return snippet ? `${lang}code: ${snippet}` : `${lang}code block`.trim();
  }
  const first = content.trim().split(/\r?\n/)[0] ?? "Artifact";
  return first.length > 48 ? `${first.slice(0, 45)}…` : first;
}

export class ArtifactsStore {
  private items: ArtifactItem[] = [];

  constructor(private storage: StorageLike) {
    this.load();
  }

  load(): void {
    try {
      const raw = this.storage.getItem(KEY);
      if (!raw) {
        this.items = [];
        return;
      }
      const parsed = JSON.parse(raw) as { items?: ArtifactItem[] };
      this.items = Array.isArray(parsed.items) ? parsed.items : [];
    } catch {
      this.items = [];
    }
  }

  persist(): void {
    this.storage.setItem(KEY, JSON.stringify({ items: this.items }));
  }

  list(): ArtifactItem[] {
    return [...this.items].sort((a, b) => b.createdAt - a.createdAt);
  }

  get(id: string): ArtifactItem | undefined {
    return this.items.find((a) => a.id === id);
  }

  add(
    content: string,
    opts?: { sourceChatId?: string; sourceMessageId?: string; title?: string },
  ): ArtifactItem | null {
    if (!shouldCaptureAsArtifact(content)) return null;
    // Prefer updating an existing capture from the same message over duplicates.
    if (opts?.sourceMessageId) {
      const existing = this.items.find((a) => a.sourceMessageId === opts.sourceMessageId);
      if (existing) {
        existing.content = content;
        existing.title = opts?.title ?? titleFromContent(content);
        existing.sourceChatId = opts.sourceChatId ?? existing.sourceChatId;
        existing.createdAt = Date.now();
        this.persist();
        return existing;
      }
    }
    const item: ArtifactItem = {
      id: uid(),
      title: opts?.title ?? titleFromContent(content),
      content,
      sourceChatId: opts?.sourceChatId,
      sourceMessageId: opts?.sourceMessageId,
      createdAt: Date.now(),
    };
    this.items.unshift(item);
    this.persist();
    return item;
  }

  delete(id: string): void {
    this.items = this.items.filter((a) => a.id !== id);
    this.persist();
  }

  clearAll(): void {
    this.items = [];
    this.persist();
  }
}
