/**
 * Direct e2b.dev client for the Electron desktop.
 *
 * Mirrors the iOS `AnyProvCore/Sandboxes/DirectE2BClient.swift` API:
 *   - createSandbox / extendTimeout / killSandbox / verifyKey
 *   - shellRun via the code-interpreter template's execute endpoint
 *
 * The desktop is treated like the iOS app: the user's E2B API key is
 * stored in safeStorage and used directly against api.e2b.dev. The
 * desktop server does NOT broker these calls — see the protocol.ts
 * comment that explicitly removed the e2b_* WS messages.
 *
 * No new top-level deps: just `fetch` (Node 20+) and the built-in
 * WebSocket. Keep the surface small and predictable.
 */

export const E2B_API_HOST = 'api.e2b.dev';
export const E2B_CODE_INTERPRETER_PORT = 49999;
export const E2B_CODE_INTERPRETER_TEMPLATE = 'code-interpreter-beta';

/** e2b.dev wire-level cap for sandbox lifetime (seconds). */
export const E2B_MAX_SANDBOX_TIMEOUT_SECONDS = 3600;
/** Public ms ceiling for the timeout knob. */
export const E2B_MAX_SANDBOX_TIMEOUT_MS = 3_600_000;

/** Returned by `createSandbox`. */
export interface E2bSandboxInfo {
  sandboxId: string;
  accessToken: string | null;
  domain: string;
  template: string;
}

/** A single `exec` response. */
export interface E2bExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  ok: boolean;
}

/** Errors surfaced to the renderer. Stable shape so the UI can switch on it. */
export type DirectE2BErrorKind =
  | 'no_api_key'
  | 'invalid_key'
  | 'http'
  | 'transport'
  | 'decoding'
  | 'unknown';

export class DirectE2BError extends Error {
  readonly kind: DirectE2BErrorKind;
  readonly status: number | null;
  readonly body: string | null;
  constructor(
    kind: DirectE2BErrorKind,
    message: string,
    opts: { status?: number; body?: string; cause?: unknown } = {}
  ) {
    super(message);
    this.name = 'DirectE2BError';
    this.kind = kind;
    this.status = opts.status ?? null;
    this.body = opts.body ?? null;
    if (opts.cause !== undefined) (this as { cause?: unknown }).cause = opts.cause;
  }
}

/** Friendly description for an error returned by the e2b.dev HTTP layer. */
export function friendlyE2BError(kind: DirectE2BErrorKind, status: number | null): string {
  if (kind === 'no_api_key') return 'Add your e2b.dev API key in Settings first.';
  if (kind === 'invalid_key')
    return 'e2b.dev rejected the API key. Paste the one from e2b.dev/dashboard?tab=keys.';
  if (status === 401 || status === 403)
    return 'e2b.dev rejected the API key. Paste the one from e2b.dev/dashboard?tab=keys.';
  if (status === 429) return 'e2b.dev is rate-limiting. Wait a moment and try again.';
  if (status !== null && status >= 500)
    return `e2b.dev is having a problem (HTTP ${status}). Try again in a minute.`;
  return 'Could not reach e2b.dev. Check your network and try again.';
}

/** Loose validator for the e2b.dev API key shape. */
export function validateE2BKey(
  raw: string | null | undefined
): { ok: true } | { ok: false; reason: string } {
  const trimmed = (raw ?? '').trim();
  if (!trimmed) return { ok: false, reason: 'Paste your e2b.dev API key.' };
  if (!trimmed.startsWith('e2b_')) return { ok: false, reason: 'e2b keys start with "e2b_".' };
  const payload = trimmed.slice('e2b_'.length);
  if (payload.length < 20)
    return { ok: false, reason: 'That key looks too short — copy it again from e2b.dev.' };
  if (!/^[A-Za-z0-9_-]+$/.test(payload))
    return { ok: false, reason: 'That key has unexpected characters.' };
  return { ok: true };
}

export class DirectE2BClient {
  private readonly apiKey: string;
  private readonly baseURL: string;

  constructor(opts: { apiKey: string; baseURL?: string } = { apiKey: '' }) {
    this.apiKey = (opts.apiKey ?? '').trim();
    this.baseURL = (opts.baseURL ?? 'https://api.e2b.dev').replace(/\/+$/, '');
  }

  private requireKey(): void {
    if (!this.apiKey) throw new DirectE2BError('no_api_key', 'e2b API key is empty');
  }

  private authHeaders(extra: Record<string, string> = {}): Record<string, string> {
    return {
      'X-API-Key': this.apiKey,
      'User-Agent': 'roamsocket-desktop',
      ...extra,
    };
  }

  /** Cheap key check: `GET /sandboxes?limit=1`. Returns the HTTP status. */
  async verifyKey(): Promise<number> {
    this.requireKey();
    const url = `${this.baseURL}/sandboxes?limit=1`;
    let res: Response;
    try {
      res = await fetch(url, { method: 'GET', headers: this.authHeaders() });
    } catch (err) {
      throw new DirectE2BError('transport', (err as Error).message, { cause: err });
    }
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new DirectE2BError('http', `verifyKey failed: ${res.status}`, {
        status: res.status,
        body,
      });
    }
    return res.status;
  }

  /** Create a fresh sandbox. `timeoutMs` is clamped to e2b.dev's 1h cap. */
  async createSandbox(
    template: string = E2B_CODE_INTERPRETER_TEMPLATE,
    timeoutMs: number = E2B_MAX_SANDBOX_TIMEOUT_MS
  ): Promise<E2bSandboxInfo> {
    this.requireKey();
    const safeTimeoutMs = Math.min(Math.max(0, Math.floor(timeoutMs)), E2B_MAX_SANDBOX_TIMEOUT_MS);
    const safeTimeoutSec = Math.min(
      Math.floor(safeTimeoutMs / 1000),
      E2B_MAX_SANDBOX_TIMEOUT_SECONDS
    );

    let res: Response;
    try {
      res = await fetch(`${this.baseURL}/sandboxes`, {
        method: 'POST',
        headers: this.authHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify({ templateID: template, timeout: safeTimeoutSec }),
      });
    } catch (err) {
      throw new DirectE2BError('transport', (err as Error).message, { cause: err });
    }
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      if (res.status === 401 || res.status === 403) {
        throw new DirectE2BError('invalid_key', 'e2b API key rejected', {
          status: res.status,
          body,
        });
      }
      throw new DirectE2BError('http', `createSandbox failed: ${res.status}`, {
        status: res.status,
        body,
      });
    }
    const raw = (await res.json().catch(() => null)) as { sandboxID?: string } | null;
    if (!raw?.sandboxID) {
      throw new DirectE2BError('decoding', 'createSandbox: missing sandboxID in response');
    }
    return {
      sandboxId: raw.sandboxID,
      accessToken: res.headers.get('X-Access-Token'),
      domain: 'e2b.dev',
      template,
    };
  }

  /** Keep a sandbox alive by resetting its TTL. */
  async extendTimeout(
    sandboxId: string,
    timeoutSeconds: number = E2B_MAX_SANDBOX_TIMEOUT_SECONDS
  ): Promise<void> {
    this.requireKey();
    if (!sandboxId) throw new DirectE2BError('unknown', 'extendTimeout: missing sandboxId');
    const safe = Math.min(Math.max(0, Math.floor(timeoutSeconds)), E2B_MAX_SANDBOX_TIMEOUT_SECONDS);
    const res = await fetch(`${this.baseURL}/sandboxes/${encodeURIComponent(sandboxId)}/timeout`, {
      method: 'POST',
      headers: this.authHeaders({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({ timeout: safe }),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new DirectE2BError('http', `extendTimeout failed: ${res.status}`, {
        status: res.status,
        body,
      });
    }
  }

  /** Best-effort kill. Swallows errors because the sandbox may have already expired. */
  async killSandbox(sandboxId: string): Promise<void> {
    this.requireKey();
    if (!sandboxId) return;
    await fetch(`${this.baseURL}/sandboxes/${encodeURIComponent(sandboxId)}`, {
      method: 'DELETE',
      headers: this.authHeaders(),
    }).catch(() => undefined);
  }

  /**
   * Run a shell command inside a sandbox via the code-interpreter
   * `/execute` endpoint. The Python shim wraps the command in a
   * `subprocess.Popen` and streams stdout/stderr back as a JSON
   * payload; we just unwrap it.
   *
   * For long-running commands, prefer `streamShellRun` so the UI can
   * show partial output.
   */
  async runShell(
    sandboxId: string,
    command: string,
    opts: { timeoutMs?: number } = {}
  ): Promise<E2bExecResult> {
    this.requireKey();
    if (!sandboxId) throw new DirectE2BError('unknown', 'runShell: missing sandboxId');
    const { timeoutMs = 30_000 } = opts;
    const script = buildRunScript(command);
    return this.execJson<E2bExecResult>(sandboxId, script, { timeoutMs });
  }

  /** Stream a shell command's stdout/stderr line-by-line via WebSocket. */
  streamShellRun(
    sandboxId: string,
    command: string,
    onLine: (line: string) => void,
    opts: { timeoutMs?: number; signal?: AbortSignal } = {}
  ): { abort: () => void } {
    this.requireKey();
    if (!sandboxId) throw new DirectE2BError('unknown', 'streamShellRun: missing sandboxId');
    const { timeoutMs = 60_000, signal } = opts;
    const port = E2B_CODE_INTERPRETER_PORT;
    const host = `${port}-${sandboxId}.e2b.dev`;
    const url = `wss://${host}/execute`;
    const ws = new WebSocket(url);
    const controller = new AbortController();
    if (signal) {
      signal.addEventListener('abort', () => controller.abort(), { once: true });
    }
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try {
        ws.close();
      } catch {
        /* ignore */
      }
    }, timeoutMs);

    ws.addEventListener('open', () => {
      try {
        ws.send(JSON.stringify({ type: 'exec', code: buildRunScript(command) }));
      } catch (err) {
        onLine(`[error] ${(err as Error).message}`);
      }
    });
    ws.addEventListener('message', (ev) => {
      const data = typeof ev.data === 'string' ? ev.data : '';
      if (!data) return;
      try {
        const parsed = JSON.parse(data) as { type?: string; line?: string; error?: string };
        if (parsed.type === 'stdout' || parsed.type === 'stderr') {
          onLine(parsed.line ?? '');
        } else if (parsed.type === 'error') {
          onLine(`[error] ${parsed.error ?? 'unknown'}`);
        }
      } catch {
        onLine(data);
      }
    });
    ws.addEventListener('error', () => {
      if (!timedOut) onLine('[error] websocket error');
    });
    ws.addEventListener('close', () => {
      clearTimeout(timer);
    });

    return {
      abort: () => {
        clearTimeout(timer);
        try {
          ws.close();
        } catch {
          /* ignore */
        }
        controller.abort();
      },
    };
  }

  /** Internal: POST JSON to the code-interpreter /execute endpoint and parse the result. */
  private async execJson<T>(
    sandboxId: string,
    code: string,
    opts: { timeoutMs?: number } = {}
  ): Promise<T> {
    const { timeoutMs = 30_000 } = opts;
    const port = E2B_CODE_INTERPRETER_PORT;
    const host = `${port}-${sandboxId}.e2b.dev`;
    const url = `https://${host}/execute`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let res: Response;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: this.authHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify({ type: 'exec', code }),
        signal: controller.signal,
      });
    } catch (err) {
      clearTimeout(timer);
      if ((err as Error).name === 'AbortError') {
        throw new DirectE2BError('transport', `exec timed out after ${timeoutMs}ms`, {
          cause: err,
        });
      }
      throw new DirectE2BError('transport', (err as Error).message, { cause: err });
    }
    clearTimeout(timer);
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new DirectE2BError('http', `exec failed: ${res.status}`, { status: res.status, body });
    }
    const text = await res.text();
    try {
      // The endpoint streams NDJSON; for `runShell` we expect a single
      // JSON object in the body. If multiple lines, return the last
      // non-empty JSON object so the caller gets the terminal state.
      const last = text
        .split('\n')
        .map((l) => l.trim())
        .filter(Boolean)
        .pop();
      if (!last) throw new DirectE2BError('decoding', 'exec: empty response');
      return JSON.parse(last) as T;
    } catch (err) {
      throw new DirectE2BError('decoding', `exec: bad JSON: ${(err as Error).message}`, {
        body: text,
      });
    }
  }
}

/** Build the Python shim the code-interpreter template runs. */
function buildRunScript(command: string): string {
  const safe = command.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
  return [
    'import subprocess, json, sys',
    'try:',
    '    p = subprocess.run(',
    `        ["bash", "-lc", "${safe}"],`,
    '        capture_output=True, text=True, timeout=60*30)',
    '    print(json.dumps({"stdout": p.stdout, "stderr": p.stderr, "exitCode": p.returncode, "ok": p.returncode == 0}))',
    'except Exception as e:',
    '    print(json.dumps({"stdout": "", "stderr": str(e), "exitCode": 1, "ok": False}))',
  ].join('\n');
}
