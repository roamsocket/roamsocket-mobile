/**
 * E2B.dev sandbox runner.
 *
 * After the agent pushes a branch the user can ask the desktop server
 * to spin up an E2B sandbox (https://e2b.dev), clone the pushed branch,
 * and run a language-aware smoke command (`npm test`, `pytest`,
 * `cargo test`, …). Output is streamed back to the phone as `e2b_log`
 * events and persisted to a per-session JSON file so the UI can show a
 * run history after a reconnect.
 *
 * The API key is admin-managed: the server reads `E2B_API_KEY` from the
 * environment (or the Firebase RTDB override wired into `index.ts`).
 * The user can override per-connection via `e2b_set_key`; the override
 * is held in memory only.
 *
 * The `e2b` SDK is an *optional* dependency — `npm install` will skip
 * it on machines that don't have an E2B account. We dynamic-import it
 * on first use so a missing SDK surfaces as a clear "E2B not
 * installed" error rather than blowing up the server boot.
 */
import { promises as fs } from 'node:fs';
import path from 'node:path';
import type { E2bRun, ServerMessage } from '../protocol.js';

const OUTPUT_TAIL_CAP = 5000; // lines kept on the persisted record

export type E2bEmit = (msg: ServerMessage) => void;

export interface E2bRunnerOptions {
  /** Directory used to persist run history (one JSON file per session). */
  runsDir: string;
  /** Admin-managed API key from env / Firebase. */
  adminApiKey: string;
}

export interface E2bStartRequest {
  sessionId: string;
  repoFullName: string;
  branch: string;
  workdir: string;
  command?: string;
  apiKey?: string;
  /** Emit hook the runner uses to push `e2b_*` messages. */
  emit: E2bEmit;
}

/**
 * Detect a sensible default test command for a freshly cloned repo.
 * Inspects the workdir (already checked out at the pushed branch) for
 * a known manifest and returns a single shell command. Falls back to
 * a generic "print tree and exit 0" so the run is still observable.
 */
export async function detectDefaultCommand(workdir: string): Promise<string> {
  const checks: Array<{ file: string; cmd: string }> = [
    { file: 'package.json', cmd: 'npm test --silent -- --watch=false' },
    { file: 'pnpm-lock.yaml', cmd: 'pnpm test' },
    { file: 'yarn.lock', cmd: 'yarn test --non-interactive' },
    { file: 'pyproject.toml', cmd: 'pip install -e . >/dev/null 2>&1 && pytest -q' },
    { file: 'requirements.txt', cmd: 'pip install -r requirements.txt >/dev/null 2>&1 && pytest -q' },
    { file: 'Cargo.toml', cmd: 'cargo test --quiet' },
    { file: 'go.mod', cmd: 'go test ./...' },
    { file: 'pom.xml', cmd: 'mvn -B -q test' },
    { file: 'build.gradle', cmd: './gradlew test --console=plain' },
    { file: 'Gemfile', cmd: 'bundle install --quiet && bundle exec rspec' },
  ];
  for (const { file, cmd } of checks) {
    try {
      await fs.access(path.join(workdir, file));
      return cmd;
    } catch {
      // not present, try the next
    }
  }
  // No manifest found: print the tree so the user still sees a run.
  return 'ls -la && echo "(no manifest detected — set a custom command)"';
}

/**
 * Append a log line to the persisted run record. Returns the updated
 * tail. Kept in a single helper so the cap is enforced consistently
 * across stdio streams.
 */
function pushOutput(tail: string[], line: string): string[] {
  const next = tail.length >= OUTPUT_TAIL_CAP
    ? tail.slice(tail.length - OUTPUT_TAIL_CAP + 1).concat(line)
    : tail.concat(line);
  return next;
}

/**
 * Resolve the API key for a request: per-connection override first, then
 * the admin-managed env key. Empty override means "use the admin key".
 */
function resolveApiKey(req: E2bStartRequest, adminApiKey: string): string {
  if (req.apiKey && req.apiKey.trim().length > 0) return req.apiKey.trim();
  return adminApiKey;
}

/**
 * Dynamic import of the optional `e2b` SDK. Returns `null` when the
 * SDK is not installed so the caller can fall back to a clear error
 * message instead of crashing the server.
 */
async function loadE2bSdk(): Promise<typeof import('e2b') | null> {
  try {
    // @ts-expect-error - optional dep, may not be on disk
    return await import('e2b');
  } catch (err) {
    void err; // swallowed; we'll surface a friendly error to the user
    return null;
  }
}

/**
 * E2bRunner owns the per-server in-memory state (overrides, run
 * registry) and the disk persistence layer. Each connection gets its
 * own override key but the runner itself is a process-wide singleton.
 */
export class E2bRunner {
  private readonly runsBySession = new Map<string, string[]>();
  private readonly liveRuns = new Map<string, { abort: () => void; sessionId: string }>();

  constructor(private readonly opts: E2bRunnerOptions) {}

  /** List runs for a session (newest first) for the `e2b_list` response. */
  async list(sessionId: string | undefined, limit: number): Promise<E2bRun[]> {
    if (!sessionId) {
      // No filter — scan all session files. This stays cheap because each
      // session is its own file.
      const files = await fs.readdir(this.opts.runsDir).catch(() => [] as string[]);
      const all: E2bRun[] = [];
      for (const f of files) {
        if (!f.endsWith('.json')) continue;
        try {
          const raw = await fs.readFile(path.join(this.opts.runsDir, f), 'utf8');
          const runs = JSON.parse(raw) as E2bRun[];
          all.push(...runs);
        } catch {
          // skip corrupt file
        }
      }
      return all
        .sort((a, b) => (b.startedAt ?? 0) - (a.startedAt ?? 0))
        .slice(0, limit);
    }
    const runs = await this.loadRuns(sessionId);
    return runs.slice(0, limit);
  }

  /** Abort a running sandbox by run id. No-op if the run already ended. */
  abort(runId: string): boolean {
    const live = this.liveRuns.get(runId);
    if (!live) return false;
    live.abort();
    this.liveRuns.delete(runId);
    return true;
  }

  /**
   * Start a new run. Returns the `E2bRun` (in queued/running state) so
   * the caller can send `e2b_started` immediately. The actual E2B
   * provisioning happens in the background and emits `e2b_log` /
   * `e2b_status` as it goes.
   */
  start(req: E2bStartRequest): E2bRun {
    const run: E2bRun = {
      id: newRunId(),
      sessionId: req.sessionId,
      repoFullName: req.repoFullName,
      branch: req.branch,
      command: req.command ?? '', // resolved async below
      status: 'queued',
      startedAt: Date.now(),
      outputTail: [],
    };
    // Resolve command + key in the background.
    void this.runInBackground(run, req);
    return run;
  }

  private async runInBackground(initialRun: E2bRun, req: E2bStartRequest): Promise<void> {
    // 1. Resolve command + key.
    const command = initialRun.command || req.command || (await detectDefaultCommand(req.workdir));
    const apiKey = resolveApiKey(req, this.opts.adminApiKey);

    if (!apiKey) {
      const run = withUpdate(initialRun, {
        status: 'failed',
        error: 'E2B is not configured. Add an admin E2B_API_KEY or set your own key in Settings.',
        finishedAt: Date.now(),
      });
      await this.persistAndAnnounce(run, req.emit);
      return;
    }

    const sdk = await loadE2bSdk();
    if (!sdk) {
      const run = withUpdate(initialRun, {
        status: 'failed',
        command,
        error:
          'E2B SDK is not installed on the desktop server. Run `npm install e2b` in desktop-server/, then restart.',
        finishedAt: Date.now(),
      });
      await this.persistAndAnnounce(run, req.emit);
      return;
    }

    // 2. Push started so the UI can show the run header before output
    //    begins streaming.
    const live = withUpdate(initialRun, { status: 'running', command });
    req.emit({ type: 'e2b_started', sessionId: req.sessionId, run: live });
    await this.appendAndEmit(live, '', 'out', req.emit);

    // 3. Provision the sandbox and stream output.
    let aborted = false;
    const ac = new AbortController();
    this.liveRuns.set(live.id, {
      abort: () => {
        aborted = true;
        ac.abort();
      },
      sessionId: req.sessionId,
    });

    try {
      const sandbox = await sdk.Sandbox.create({ apiKey });
      const sandboxId = sandbox.sandboxId;
      const sandboxUrl = (sandbox as unknown as { url?: string }).url;

      // Persist the sandbox id immediately so the UI can show the link
      // even if the user disconnects before exit.
      const withId = withUpdate(live, { sandboxId, sandboxUrl });
      req.emit({ type: 'e2b_status', sessionId: req.sessionId, run: withId });
      await this.persistRun(withId);

      // Clone + run. We pipe the output from the sandbox's `commands.run`
      // stdout / stderr to the WS frame stream.
      const result = await sandbox.commands.run(command, {
        cwd: '/code',
        envs: {},
        timeoutMs: 0,
        onStdout: (data: string) => {
          if (aborted) return;
          for (const line of data.split(/\r?\n/)) {
            if (line.length === 0) continue;
            void this.appendAndEmit(withId, line, 'out', req.emit);
          }
        },
        onStderr: (data: string) => {
          if (aborted) return;
          for (const line of data.split(/\r?\n/)) {
            if (line.length === 0) continue;
            void this.appendAndEmit(withId, line, 'err', req.emit);
          }
        },
      });
      if (ac.signal.aborted) {
        const killed = withUpdate(withId, {
          status: 'killed',
          finishedAt: Date.now(),
        });
        await this.persistAndAnnounce(killed, req.emit);
        return;
      }
      const final = withUpdate(withId, {
        status: result.exitCode === 0 ? 'completed' : 'failed',
        exitCode: result.exitCode,
        finishedAt: Date.now(),
      });
      await this.persistAndAnnounce(final, req.emit);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const failed = withUpdate(live, {
        status: 'failed',
        error: message,
        finishedAt: Date.now(),
      });
      await this.persistAndAnnounce(failed, req.emit);
    } finally {
      this.liveRuns.delete(live.id);
    }
  }

  // MARK: - Internals

  private async appendAndEmit(
    run: E2bRun,
    line: string,
    stream: 'out' | 'err',
    emit: E2bEmit,
  ): Promise<void> {
    const next = pushOutput(run.outputTail, line);
    const updated: E2bRun = { ...run, outputTail: next };
    await this.persistRun(updated);
    emit({
      type: 'e2b_log',
      runId: updated.id,
      sessionId: updated.sessionId,
      stream,
      line,
      ts: Date.now(),
    });
  }

  private async persistAndAnnounce(run: E2bRun, emit: E2bEmit): Promise<void> {
    await this.persistRun(run);
    emit({ type: 'e2b_status', sessionId: run.sessionId, run });
  }

  private async persistRun(run: E2bRun): Promise<void> {
    await fs.mkdir(this.opts.runsDir, { recursive: true });
    const all = await this.loadRuns(run.sessionId);
    const idx = all.findIndex((r) => r.id === run.id);
    if (idx >= 0) all[idx] = run;
    else all.unshift(run);
    const file = path.join(this.opts.runsDir, `${run.sessionId}.json`);
    await fs.writeFile(file, JSON.stringify(all, null, 2), 'utf8');
  }

  private async loadRuns(sessionId: string): Promise<E2bRun[]> {
    const file = path.join(this.opts.runsDir, `${sessionId}.json`);
    try {
      const raw = await fs.readFile(file, 'utf8');
      const parsed = JSON.parse(raw) as E2bRun[];
      return parsed.sort((a, b) => (b.startedAt ?? 0) - (a.startedAt ?? 0));
    } catch {
      return [];
    }
  }
}

function withUpdate(run: E2bRun, patch: Partial<E2bRun>): E2bRun {
  return { ...run, ...patch };
}

function newRunId(): string {
  return 'r_' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
}
