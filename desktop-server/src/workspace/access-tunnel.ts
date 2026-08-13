/**
 * Singleton public tunnel for the coding server itself (not per-app ports).
 *
 * When a phone pairs on the LAN we start Cloudflare / ngrok / localtunnel
 * against the desktop HTTP port, then push the HTTPS URL so the app can
 * reconnect off-LAN without re-pairing.
 */
import {
  listTunnels,
  startTunnel,
  stopTunnel,
  type TunnelInfo,
  type TunnelProvider,
} from './tunnels.js';

let tunnelId: string | null = null;
let portBound: number | null = null;
let inFlight: Promise<TunnelInfo> | null = null;
/** Bumped on force-stop so a superseded in-flight start never reclaims ownership. */
let generation = 0;

export function accessTunnelId(): string | null {
  return tunnelId;
}

export function currentAccessTunnel(): TunnelInfo | null {
  if (!tunnelId) return null;
  return listTunnels().find((t) => t.id === tunnelId) ?? null;
}

/**
 * Ensure a public tunnel is running for `port`. Concurrent callers share one
 * promise so we never spawn two cloudflared processes for the same server.
 *
 * Pass `force: true` when the phone could not reach the current public URL —
 * tears down the existing process and starts a fresh tunnel.
 */
export async function ensureAccessTunnel(opts: {
  port: number;
  provider?: TunnelProvider;
  /** Max ms to wait for a public URL after spawn (default 45s). */
  waitMs?: number;
  /** Stop any live access tunnel and open a new one (new public URL). */
  force?: boolean;
}): Promise<TunnelInfo> {
  const waitMs = opts.waitMs ?? 45_000;
  const provider = opts.provider ?? 'auto';

  if (opts.force) {
    stopAccessTunnel();
  }

  if (portBound !== null && portBound !== opts.port && tunnelId) {
    stopTunnel(tunnelId);
    tunnelId = null;
    portBound = null;
  }
  portBound = opts.port;

  const existing = currentAccessTunnel();
  if (existing && !opts.force) {
    if (existing.status === 'up' && existing.url) return existing;
    if (existing.status === 'starting' || (existing.status === 'up' && !existing.url)) {
      return waitForUrl(existing.id, waitMs);
    }
    // error / stopped — fall through and restart
    if (tunnelId) {
      stopTunnel(tunnelId);
      tunnelId = null;
    }
  }

  if (inFlight && !opts.force) return inFlight;

  const gen = generation;
  inFlight = (async () => {
    try {
      const started = await startTunnel({ port: opts.port, provider });
      // A force-restart may have superseded this spawn.
      if (gen !== generation) {
        stopTunnel(started.id);
        return (
          currentAccessTunnel() ?? {
            ...started,
            status: 'stopped' as const,
            error: 'Superseded by a newer tunnel restart.',
          }
        );
      }
      tunnelId = started.id;
      if (started.url && started.status === 'up') return started;
      if (started.status === 'error') return started;
      return waitForUrl(started.id, waitMs);
    } finally {
      if (gen === generation) inFlight = null;
    }
  })();

  return inFlight;
}

export function stopAccessTunnel(): void {
  generation += 1;
  if (tunnelId) {
    stopTunnel(tunnelId);
    tunnelId = null;
  }
  portBound = null;
  inFlight = null;
}

async function waitForUrl(id: string, waitMs: number): Promise<TunnelInfo> {
  const deadline = Date.now() + waitMs;
  while (Date.now() < deadline) {
    const live = listTunnels().find((t) => t.id === id);
    if (!live) {
      return {
        id,
        port: portBound ?? 0,
        provider: 'unknown',
        status: 'error',
        error: 'Tunnel process disappeared.',
      };
    }
    if (live.url) {
      return { ...live, status: live.status === 'starting' ? 'up' : live.status };
    }
    if (live.status === 'error' || live.status === 'stopped') return live;
    await new Promise((r) => setTimeout(r, 250));
  }
  const live = listTunnels().find((t) => t.id === id);
  return (
    live ?? {
      id,
      port: portBound ?? 0,
      provider: 'unknown',
      status: 'error',
      error: 'Timed out waiting for a public tunnel URL.',
    }
  );
}
