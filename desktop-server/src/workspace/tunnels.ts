/**
 * Instant public tunnels for local ports. Detects installed CLIs and
 * falls back to `npx localtunnel` when nothing else is present.
 *
 * Supported providers:
 *   - ngrok        (`ngrok http <port>`)
 *   - cloudflare   (`cloudflared tunnel --url http://localhost:<port>`)
 *   - localtunnel  (`lt --port <port>` or `npx --yes localtunnel --port <port>`)
 *   - bore         (`bore local <port> --to bore.pub`)
 *   - auto         first available from the list above
 *
 * "Vercel" does not ship a classic reverse tunnel for arbitrary ports;
 * the app surfaces Cloudflare / ngrok / localtunnel instead, which
 * produce the same kind of public HTTPS URL for previewing local servers.
 */
import { spawn, type ChildProcess, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import { pathWithManagedBin, resolveTunnelBin } from './tunnel-clis.js';

const execFileP = promisify(execFile);

export type TunnelProvider = 'auto' | 'ngrok' | 'cloudflare' | 'localtunnel' | 'bore';

export interface TunnelInfo {
  id: string;
  port: number;
  provider: string;
  status: 'starting' | 'up' | 'error' | 'stopped';
  url?: string;
  error?: string;
}

interface LiveTunnel extends TunnelInfo {
  proc: ChildProcess;
  buffer: string;
}

const tunnels = new Map<string, LiveTunnel>();

const PROVIDER_BINS: { name: Exclude<TunnelProvider, 'auto'>; bin: string }[] = [
  { name: 'ngrok', bin: 'ngrok' },
  { name: 'cloudflare', bin: 'cloudflared' },
  { name: 'localtunnel', bin: 'lt' },
  { name: 'bore', bin: 'bore' },
];

async function hasBin(bin: string): Promise<boolean> {
  if (bin === 'ngrok' || bin === 'cloudflared') {
    return (await resolveTunnelBin(bin)) != null;
  }
  try {
    await execFileP(process.platform === 'win32' ? 'where' : 'which', [bin], {
      env: pathWithManagedBin(),
    });
    return true;
  } catch {
    return false;
  }
}

/** Providers the desktop can start right now. */
export async function detectTunnelProviders(): Promise<string[]> {
  const found: string[] = [];
  for (const p of PROVIDER_BINS) {
    if (await hasBin(p.bin)) found.push(p.name);
  }
  // Node is always present for this server — localtunnel via npx is a free fallback.
  if (!found.includes('localtunnel')) found.push('localtunnel');
  return found;
}

async function resolveProvider(
  requested: TunnelProvider
): Promise<Exclude<TunnelProvider, 'auto'>> {
  if (requested !== 'auto') return requested;
  const available = await detectTunnelProviders();
  // Prefer dedicated CLIs when installed; localtunnel last (always available via npx).
  for (const name of ['cloudflare', 'ngrok', 'bore', 'localtunnel'] as const) {
    if (available.includes(name)) return name;
  }
  return 'localtunnel';
}

async function spawnArgs(
  provider: Exclude<TunnelProvider, 'auto'>,
  port: number
): Promise<{ cmd: string; args: string[]; shell?: boolean }> {
  const win = process.platform === 'win32';
  switch (provider) {
    case 'ngrok': {
      const bin = (await resolveTunnelBin('ngrok')) ?? (win ? 'ngrok.exe' : 'ngrok');
      return { cmd: bin, args: ['http', String(port), '--log=stdout', '--log-format=json'] };
    }
    case 'cloudflare': {
      const bin =
        (await resolveTunnelBin('cloudflared')) ?? (win ? 'cloudflared.exe' : 'cloudflared');
      return { cmd: bin, args: ['tunnel', '--url', `http://127.0.0.1:${port}`] };
    }
    case 'localtunnel': {
      // Prefer global `lt`; otherwise npx (npx.cmd on Windows).
      if (await hasBin('lt')) {
        return { cmd: win ? 'lt.cmd' : 'lt', args: ['--port', String(port)], shell: win };
      }
      return {
        cmd: win ? 'npx.cmd' : 'npx',
        args: ['--yes', 'localtunnel', '--port', String(port)],
        shell: win,
      };
    }
    case 'bore':
      return { cmd: win ? 'bore.exe' : 'bore', args: ['local', String(port), '--to', 'bore.pub'] };
  }
}

/** Regexes that capture a public HTTPS URL from provider stdout/stderr. */
const URL_PATTERNS: RegExp[] = [
  /https:\/\/[a-zA-Z0-9][-a-zA-Z0-9.]*trycloudflare\.com/i,
  /https:\/\/[a-zA-Z0-9][-a-zA-Z0-9.]*ngrok(?:-free)?\.(?:app|io|dev)/i,
  /your url is:\s*(https:\/\/\S+)/i,
  /https:\/\/[a-zA-Z0-9][-a-zA-Z0-9.]*loca\.lt/i,
  /https:\/\/[a-zA-Z0-9][-a-zA-Z0-9.]*localtunnel\.me/i,
  /bore\.pub:(\d+)/i, // bore prints host:port
  /https?:\/\/[a-zA-Z0-9][-a-zA-Z0-9.]*bore\.pub(?::\d+)?/i,
  /url=(https:\/\/\S+)/i,
  /"url"\s*:\s*"(https:\/\/[^"]+)"/i,
];

function extractUrl(chunk: string): string | undefined {
  for (const re of URL_PATTERNS) {
    const m = chunk.match(re);
    if (!m) continue;
    if (re.source.includes('bore\\.pub:(\\d+)')) {
      return `https://bore.pub:${m[1]}`;
    }
    return (m[1] ?? m[0]).replace(/[.,;)\]]+$/, '');
  }
  return undefined;
}

export async function startTunnel(opts: {
  port: number;
  provider?: TunnelProvider;
}): Promise<TunnelInfo> {
  const provider = await resolveProvider(opts.provider ?? 'auto');
  const id = randomUUID();
  const { cmd, args, shell } = await spawnArgs(provider, opts.port);

  const proc = spawn(cmd, args, {
    env: { ...pathWithManagedBin(), FORCE_COLOR: '0' },
    stdio: ['ignore', 'pipe', 'pipe'],
    shell: shell ?? false,
    windowsHide: true,
  });

  const live: LiveTunnel = {
    id,
    port: opts.port,
    provider,
    status: 'starting',
    proc,
    buffer: '',
  };
  tunnels.set(id, live);

  const onData = (buf: Buffer) => {
    const text = buf.toString('utf8');
    live.buffer += text;
    if (live.status === 'starting' || !live.url) {
      const url = extractUrl(live.buffer);
      if (url) {
        live.url = url;
        live.status = 'up';
      }
    }
  };
  proc.stdout?.on('data', onData);
  proc.stderr?.on('data', onData);
  proc.on('error', (err) => {
    live.status = 'error';
    live.error = err.message;
  });
  proc.on('exit', (code) => {
    if (live.status !== 'up') {
      live.status = 'error';
      live.error =
        live.error ??
        `Tunnel exited (code ${code ?? '?'}). Last output: ${live.buffer.trim().slice(-400) || '(none)'}`;
    } else {
      live.status = 'stopped';
    }
  });

  // Wait briefly for a URL so the first response is useful.
  const deadline = Date.now() + 12_000;
  while (Date.now() < deadline && live.status === 'starting') {
    await new Promise((r) => setTimeout(r, 200));
  }
  if (live.status === 'starting') {
    // Still starting — return current state; client can refresh.
    // Leave process running; URL may arrive later.
  }

  return publicInfo(live);
}

export function stopTunnel(id: string): TunnelInfo | null {
  const live = tunnels.get(id);
  if (!live) return null;
  try {
    if (process.platform === 'win32') {
      // SIGTERM is not meaningful for many Win32 console apps.
      live.proc.kill();
    } else {
      live.proc.kill('SIGTERM');
    }
  } catch {
    /* ignore */
  }
  live.status = 'stopped';
  tunnels.delete(id);
  return publicInfo(live);
}

export function listTunnels(): TunnelInfo[] {
  return [...tunnels.values()].map(publicInfo);
}

function publicInfo(t: LiveTunnel): TunnelInfo {
  return {
    id: t.id,
    port: t.port,
    provider: t.provider,
    status: t.status,
    url: t.url,
    error: t.error,
  };
}
