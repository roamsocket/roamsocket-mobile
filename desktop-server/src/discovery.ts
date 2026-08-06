/**
 * Local-network discovery (Bonjour / mDNS).
 *
 * The desktop publishes `_anyprov-code._tcp` so phones on the same LAN can
 * find the coding server without typing an IP. Pairing still requires the
 * 6-digit code — we never put secrets in the TXT record.
 *
 * Service type must stay in sync with iOS:
 *   ios/AnyProvCore/.../Server/ServerDiscovery.swift
 *   Info.plist → NSBonjourServices
 */
import os from "node:os";
import Bonjour from "bonjour-service";

/** Bonjour service type (without leading underscore / protocol). */
export const APC_BONJOUR_TYPE = "anyprov-code";

export interface AdvertiseOptions {
  name: string;
  port: number;
  version: string;
  /** When false, skip advertising (e.g. unit tests). Default true. */
  enabled?: boolean;
}

export interface Advertisement {
  stop: () => Promise<void>;
}

/**
 * Publish this server on the local network. Safe to call when the HTTP
 * server is already listening. Failures are logged and swallowed so a
 * broken mDNS stack never takes down the coding server.
 */
export function advertiseServer(opts: AdvertiseOptions): Advertisement {
  if (opts.enabled === false) {
    return { stop: async () => undefined };
  }

  let bonjour: InstanceType<typeof Bonjour> | null = null;
  let stopped = false;

  try {
    bonjour = new Bonjour();
    const hostLabel = os.hostname().replace(/\.local$/i, "") || "desktop";
    const serviceName = `${opts.name} (${hostLabel})`.slice(0, 63);

    bonjour.publish({
      name: serviceName,
      type: APC_BONJOUR_TYPE,
      protocol: "tcp",
      port: opts.port,
      txt: {
        name: opts.name,
        version: opts.version,
        path: "/",
      },
    });
  } catch (err) {
    console.warn(`[apc] Bonjour advertise failed: ${(err as Error).message}`);
    bonjour = null;
  }

  return {
    stop: async () => {
      if (stopped) return;
      stopped = true;
      if (!bonjour) return;
      await new Promise<void>((resolve) => {
        try {
          bonjour!.unpublishAll(() => {
            bonjour!.destroy();
            resolve();
          });
        } catch {
          try {
            bonjour!.destroy();
          } catch {
            /* ignore */
          }
          resolve();
        }
      });
    },
  };
}

/** Non-loopback IPv4 addresses useful for pair-with-phone banners. */
export function lanIPv4Addresses(): string[] {
  const out: string[] = [];
  const ifaces = os.networkInterfaces();
  for (const entries of Object.values(ifaces)) {
    if (!entries) continue;
    for (const e of entries) {
      if (e.family === "IPv4" && !e.internal) out.push(e.address);
    }
  }
  return out;
}
