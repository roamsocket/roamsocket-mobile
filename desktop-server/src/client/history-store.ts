/**
 * Chat history store with injectable storage (localStorage in renderer, Map in tests).
 */
export interface ChatMessageRecord {
  id: string;
  role: "user" | "assistant";
  content: string;
  createdAt: number;
}

export interface ChatThread {
  id: string;
  title: string;
  messages: ChatMessageRecord[];
  updatedAt: number;
  starred: boolean;
  archived: boolean;
  provider: string;
  model: string;
  /** Project id when this chat lives inside a project. */
  projectId?: string;
  titleIsUserEdited: boolean;
}

export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem?(key: string): void;
}

const KEY = "apc.chats.v1";

function uid(prefix = "c"): string {
  return `${prefix}_${Math.random().toString(36).slice(2, 10)}${Date.now().toString(36).slice(-4)}`;
}

export function newMessage(
  role: ChatMessageRecord["role"],
  content: string,
): ChatMessageRecord {
  return { id: uid("m"), role, content, createdAt: Date.now() };
}

export function autoTitleFromMessages(messages: ChatMessageRecord[]): string {
  const firstUser = messages.find((m) => m.role === "user" && m.content.trim());
  if (!firstUser) return "New chat";
  const t = firstUser.content.trim().replace(/\s+/g, " ");
  return t.length > 48 ? `${t.slice(0, 45)}…` : t;
}

export class HistoryStore {
  private threads: ChatThread[] = [];
  activeChatId: string | null = null;

  constructor(private storage: StorageLike) {
    this.load();
  }

  load(): void {
    try {
      const raw = this.storage.getItem(KEY);
      if (!raw) {
        this.threads = [];
        this.activeChatId = null;
        return;
      }
      const parsed = JSON.parse(raw) as {
        threads?: ChatThread[];
        activeChatId?: string | null;
      };
      this.threads = Array.isArray(parsed.threads) ? parsed.threads : [];
      this.activeChatId = parsed.activeChatId ?? null;
    } catch {
      this.threads = [];
      this.activeChatId = null;
    }
  }

  persist(): void {
    this.storage.setItem(
      KEY,
      JSON.stringify({ threads: this.threads, activeChatId: this.activeChatId }),
    );
  }

  /**
   * Active (non-archived) chats.
   * - omit / `undefined` projectId → all chats
   * - string projectId → only chats in that project
   */
  listActive(projectId?: string): ChatThread[] {
    return this.threads
      .filter((t) => !t.archived)
      .filter((t) => (projectId === undefined ? true : t.projectId === projectId))
      .sort((a, b) => {
        if (a.starred !== b.starred) return a.starred ? -1 : 1;
        return b.updatedAt - a.updatedAt;
      });
  }

  get(id: string): ChatThread | undefined {
    return this.threads.find((t) => t.id === id);
  }

  beginNewChat(opts?: {
    provider?: string;
    model?: string;
    projectId?: string;
  }): ChatThread {
    const thread: ChatThread = {
      id: uid("chat"),
      title: "New chat",
      messages: [],
      updatedAt: Date.now(),
      starred: false,
      archived: false,
      provider: opts?.provider ?? "anthropic",
      model: opts?.model ?? "",
      projectId: opts?.projectId,
      titleIsUserEdited: false,
    };
    this.threads.unshift(thread);
    this.activeChatId = thread.id;
    this.persist();
    return thread;
  }

  ensureActive(opts?: {
    provider?: string;
    model?: string;
    projectId?: string;
  }): ChatThread {
    if (this.activeChatId) {
      const existing = this.get(this.activeChatId);
      if (existing && !existing.archived) {
        // If caller wants a project-scoped chat and the active one is not
        // in that project, start a new project chat instead of reusing.
        if (opts?.projectId && existing.projectId !== opts.projectId) {
          return this.beginNewChat(opts);
        }
        return existing;
      }
    }
    return this.beginNewChat(opts);
  }

  setActive(id: string | null): void {
    this.activeChatId = id;
    this.persist();
  }

  appendMessage(chatId: string, message: ChatMessageRecord): ChatThread | undefined {
    const t = this.get(chatId);
    if (!t) return undefined;
    t.messages.push(message);
    t.updatedAt = Date.now();
    if (!t.titleIsUserEdited) {
      t.title = autoTitleFromMessages(t.messages);
    }
    this.persist();
    return t;
  }

  updateLastAssistant(chatId: string, content: string): void {
    const t = this.get(chatId);
    if (!t) return;
    for (let i = t.messages.length - 1; i >= 0; i--) {
      if (t.messages[i]!.role === "assistant") {
        t.messages[i]!.content = content;
        t.updatedAt = Date.now();
        this.persist();
        return;
      }
    }
  }

  setModel(chatId: string, provider: string, model: string): void {
    const t = this.get(chatId);
    if (!t) return;
    t.provider = provider;
    t.model = model;
    this.persist();
  }

  rename(chatId: string, title: string): void {
    const t = this.get(chatId);
    if (!t) return;
    t.title = title.trim() || "New chat";
    t.titleIsUserEdited = true;
    this.persist();
  }

  setStarred(chatId: string, starred: boolean): void {
    const t = this.get(chatId);
    if (!t) return;
    t.starred = starred;
    this.persist();
  }

  archive(chatId: string): void {
    const t = this.get(chatId);
    if (!t) return;
    t.archived = true;
    if (this.activeChatId === chatId) this.activeChatId = null;
    this.persist();
  }

  delete(chatId: string): void {
    this.threads = this.threads.filter((t) => t.id !== chatId);
    if (this.activeChatId === chatId) this.activeChatId = null;
    this.persist();
  }

  /** Drop empty "New chat" drafts when leaving. */
  discardIfBlank(chatId: string): void {
    const t = this.get(chatId);
    if (!t) return;
    if (t.messages.length === 0 && !t.titleIsUserEdited) {
      this.delete(chatId);
    }
  }
}

/** In-memory storage for unit tests. */
export function memoryStorage(seed: Record<string, string> = {}): StorageLike {
  const map = new Map(Object.entries(seed));
  return {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => {
      map.set(k, v);
    },
    removeItem: (k) => {
      map.delete(k);
    },
  };
}
