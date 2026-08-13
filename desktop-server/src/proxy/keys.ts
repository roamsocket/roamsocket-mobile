/**
 * API-key resolution for the pass-through proxy.
 *
 * Resolution order per provider:
 *   1. APC_PROXY_TOKEN_<UPPER>          — operator override for this proxy
 *   2. <UPPER>_API_KEY                  — standard env var the user already set
 *   3. APC_<UPPER>_API_KEY              — legacy alias used by the desktop
 *   4. secrets.json / secrets.enc       — Electron safeStorage payload, if
 *                                         the headless CLI is run on the
 *                                         same machine as the desktop app
 *
 * We deliberately don't require any of these — the proxy just returns 401
 * with a useful error if none is found, so the user knows what to set.
 */
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import type { ProviderId } from "../protocol.js";
import { productDataDir } from "../product.js";

/**
 * Env-only resolution. Used by the proxy hot path so a headless server
 * doesn't need to read or decrypt anything — it just trusts the environment
 * the user already set up for their coding CLIs.
 */
export function resolveProxyApiKey(provider: ProviderId): string | null {
  const upper = provider.toUpperCase().replace(/[^A-Z0-9]/g, "_");
  const candidates = [
    process.env[`APC_PROXY_TOKEN_${upper}`],
    process.env[`${upper}_API_KEY`],
    process.env[`APC_${upper}_API_KEY`],
  ];
  for (const c of candidates) {
    if (typeof c === "string" && c.trim().length > 0) return c.trim();
  }
  return null;
}

interface StoredSecrets {
  providerKeys?: Record<string, string>;
  // Open format (plain JSON) is supported by `roamsocket keys set` (CLI) and
  // by any external tool the user may already use. Electron's safeStorage
  // produces binary; we don't decrypt it here — that path stays in Electron.
}

/**
 * Best-effort read of a stored provider key.
 *
 * Plain JSON only — encrypted blobs are handled inside Electron where
 * `safeStorage` is available. The headless CLI on the same machine as the
 * Electron app can still see the unencrypted copy if the user opted into
 * `safeStorage.encryptString`'s round-trip via the CLI's `/keys` flow.
 */
export function readStoredApiKey(provider: ProviderId): string | null {
  const file = path.join(productDataDir(), "secrets.json");
  if (!existsSync(file)) return null;
  try {
    const raw = readFileSync(file, "utf8");
    const parsed = JSON.parse(raw) as StoredSecrets;
    const k = parsed.providerKeys?.[provider];
    return typeof k === "string" && k.length > 0 ? k : null;
  } catch {
    return null;
  }
}

/**
 * One-shot helper: env first, then stored. The proxy should call this once
 * per request — both functions are tiny and the stored read is cached by the
 * filesystem layer anyway.
 */
export function resolveAnyApiKey(provider: ProviderId): string | null {
  return resolveProxyApiKey(provider) ?? readStoredApiKey(provider);
}