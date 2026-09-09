import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
/**
 * Persisted log of phone-style E2B runs started by the desktop.
 *
 * Mirrors the iOS `SandboxesStore.phoneRuns` / `PhoneRunPersistence`
 * shape: each row records the user command, the e2b sandbox id, the
 * status, and the streamed output. Runs are written to
 * `<userData>/sandbox-runs.v1.json` on every mutation.
 *
 * The store is intentionally synchronous-on-disk: a sandbox run is
 * a user-visible unit and losing the run history on a crash would be
 * surprising.
 */
import { app } from 'electron';

const FILE_NAME = 'sandbox-runs.v1.json';

export type SandboxRunStatus = 'queued' | 'running' | 'completed' | 'failed' | 'killed';

/** A single command run, the way the Sandboxes view presents it. */
export interface SandboxRun {
  id: string;
  /** Free-form origin tag — always 'desktop' for now. */
  source: 'desktop';
  command: string;
  status: SandboxRunStatus;
  exitCode: number | null;
  sandboxId: string | null;
  sandboxUrl: string | null;
  startedAt: number | null;
  finishedAt: number | null;
  outputTail: string[];
  error: string | null;
}

function storePath(): string {
  return `${app.getPath('userData')}/${FILE_NAME}`;
}

function readAll(): SandboxRun[] {
  const path = storePath();
  if (!existsSync(path)) return [];
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8')) as { runs?: SandboxRun[] };
    if (!Array.isArray(parsed.runs)) return [];
    return parsed.runs;
  } catch {
    return [];
  }
}

function writeAll(runs: SandboxRun[]): void {
  const path = storePath();
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify({ runs }, null, 2), { mode: 0o600 });
}

/** Hydrate the store. Mark any in-flight runs as killed (the sandbox is gone). */
export function loadSandboxRuns(): SandboxRun[] {
  const raw = readAll();
  const now = Date.now();
  const normalized = raw.map((run) => {
    if (run.status === 'running' || run.status === 'queued') {
      return {
        ...run,
        status: 'killed' as const,
        error: 'Desktop was closed before the run finished.',
        finishedAt: run.finishedAt ?? now,
      };
    }
    return run;
  });
  if (JSON.stringify(normalized) !== JSON.stringify(raw)) {
    writeAll(normalized);
  }
  // Newest first.
  return normalized.slice().sort((a, b) => (b.startedAt ?? 0) - (a.startedAt ?? 0));
}

export function appendSandboxRun(run: SandboxRun): SandboxRun[] {
  const all = readAll();
  all.unshift(run);
  writeAll(all);
  return loadSandboxRuns();
}

export function updateSandboxRun(id: string, patch: Partial<SandboxRun>): SandboxRun[] {
  const all = readAll();
  const next = all.map((r) => (r.id === id ? { ...r, ...patch } : r));
  writeAll(next);
  return loadSandboxRuns();
}

export function clearSandboxRuns(): void {
  writeAll([]);
}
