/**
 * Local history of coding sessions for the Code home screen.
 */
import type { StorageLike } from './history-store.js';
import type { GitHubPrState } from './github-pr.js';

export type CodeSessionStatus = 'working' | 'needs_input' | 'ready_for_review' | 'done' | 'error';

export interface CodeSessionRecord {
  id: string;
  /** Wire protocol session id once created */
  wireSessionId: string | null;
  title: string;
  repo: string;
  baseBranch: string;
  workBranch: string;
  provider: string;
  model: string;
  status: CodeSessionStatus;
  prUrl?: string;
  /** GitHub PR number when known */
  prNumber?: number;
  /** Live-ish PR state for chip colors (open / draft / merged / closed) */
  prState?: GitHubPrState;
  /** Head branch shown on the PR chip */
  prBranch?: string;
  detail?: string;
  /** User dismissed the PR chip for this session */
  prDismissed?: boolean;
  createdAt: number;
  updatedAt: number;
}

const KEY = 'apc.codeSessions.v1';

function uid(): string {
  return `cs_${Math.random().toString(36).slice(2, 10)}${Date.now().toString(36).slice(-4)}`;
}

export class CodeSessionsStore {
  private sessions: CodeSessionRecord[] = [];

  constructor(private storage: StorageLike) {
    this.load();
  }

  load(): void {
    try {
      const raw = this.storage.getItem(KEY);
      if (!raw) {
        this.sessions = [];
        return;
      }
      const parsed = JSON.parse(raw) as { sessions?: CodeSessionRecord[] };
      this.sessions = Array.isArray(parsed.sessions) ? parsed.sessions : [];
    } catch {
      this.sessions = [];
    }
  }

  persist(): void {
    this.storage.setItem(KEY, JSON.stringify({ sessions: this.sessions }));
  }

  list(): CodeSessionRecord[] {
    return [...this.sessions].sort((a, b) => b.updatedAt - a.updatedAt);
  }

  get(id: string): CodeSessionRecord | undefined {
    return this.sessions.find((s) => s.id === id);
  }

  getByWireId(wireSessionId: string): CodeSessionRecord | undefined {
    return this.sessions.find((s) => s.wireSessionId === wireSessionId);
  }

  create(partial: {
    title: string;
    repo: string;
    baseBranch: string;
    workBranch: string;
    provider: string;
    model: string;
  }): CodeSessionRecord {
    const now = Date.now();
    const rec: CodeSessionRecord = {
      id: uid(),
      wireSessionId: null,
      title: partial.title.slice(0, 80) || 'Coding session',
      repo: partial.repo,
      baseBranch: partial.baseBranch,
      workBranch: partial.workBranch,
      provider: partial.provider,
      model: partial.model,
      status: 'working',
      createdAt: now,
      updatedAt: now,
    };
    this.sessions.unshift(rec);
    this.persist();
    return rec;
  }

  update(
    id: string,
    patch: Partial<
      Pick<
        CodeSessionRecord,
        | 'wireSessionId'
        | 'title'
        | 'status'
        | 'prUrl'
        | 'prNumber'
        | 'prState'
        | 'prBranch'
        | 'prDismissed'
        | 'detail'
        | 'updatedAt'
      >
    >
  ): void {
    const s = this.get(id);
    if (!s) return;
    Object.assign(s, patch, { updatedAt: Date.now() });
    this.persist();
  }

  delete(id: string): void {
    this.sessions = this.sessions.filter((s) => s.id !== id);
    this.persist();
  }
}

export function relativeTime(ts: number, now = Date.now()): string {
  const sec = Math.max(0, Math.floor((now - ts) / 1000));
  if (sec < 60) return 'just now';
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day === 1) return 'yesterday';
  if (day < 14) return `${day}d ago`;
  return new Date(ts).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
