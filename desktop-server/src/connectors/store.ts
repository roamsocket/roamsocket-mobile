/**
 * Persisted connector credentials + runtime state. Mirrors the pattern in
 * `desktop-config.ts`: a plain JSON file under the product data dir. This is
 * a single-user local desktop tool (like the skills/MCP repo tokens already
 * stored in `config.json`), so this is not encrypted-at-rest; treat the file
 * like any other local credential store on your machine.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { productDataDir } from "../product.js";
import { connectorDefinition } from "./catalog.js";

export interface StoredConnector {
  id: string;
  /** Token-auth: the raw token/PAT the user pasted in. */
  token?: string;
  /** OAuth2: the user's own app credentials (BYO OAuth app). */
  clientId?: string;
  clientSecret?: string;
  /** OAuth2: tokens obtained from the provider. */
  accessToken?: string;
  refreshToken?: string;
  /** Epoch ms when `accessToken` expires. */
  expiresAt?: number;
  lastError?: string;
}

interface ConnectorFile {
  connectors: Record<string, StoredConnector>;
}

function filePath(): string {
  return path.join(productDataDir(), "connectors.json");
}

function load(): ConnectorFile {
  try {
    const raw = readFileSync(filePath(), "utf8");
    const parsed = JSON.parse(raw) as Partial<ConnectorFile>;
    return { connectors: parsed.connectors ?? {} };
  } catch {
    return { connectors: {} };
  }
}

function save(file: ConnectorFile): void {
  try {
    const dir = productDataDir();
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    writeFileSync(filePath(), JSON.stringify(file, null, 2));
  } catch {
    // best effort — same policy as desktop-config.ts
  }
}

export function getStoredConnector(id: string): StoredConnector | undefined {
  return load().connectors[id];
}

export function upsertStoredConnector(id: string, patch: Partial<StoredConnector>): StoredConnector {
  const file = load();
  const current = file.connectors[id] ?? { id };
  const next: StoredConnector = { ...current, ...patch, id };
  file.connectors[id] = next;
  save(file);
  return next;
}

export function clearStoredConnector(id: string): void {
  const file = load();
  delete file.connectors[id];
  save(file);
}

export function listStoredConnectors(): StoredConnector[] {
  return Object.values(load().connectors);
}

/** True when the connector currently has usable credentials. */
export function isConnectorConnected(id: string): boolean {
  const def = connectorDefinition(id);
  if (!def || def.authType === "unsupported") return false;
  const stored = getStoredConnector(id);
  if (!stored) return false;
  if (def.authType === "token") return !!stored.token;
  if (def.authType === "oauth2") {
    return !!stored.accessToken || !!stored.refreshToken;
  }
  return false;
}

/**
 * Build the auth header for an authenticated request, refreshing an expired
 * OAuth2 access token first when a refresh token is available.
 */
export async function resolveAuthHeader(
  id: string,
): Promise<{ header: Record<string, string> } | { error: string }> {
  const def = connectorDefinition(id);
  if (!def) return { error: `Unknown connector: ${id}` };
  if (def.authType === "unsupported") {
    return { error: def.helpText };
  }
  const stored = getStoredConnector(id);
  if (!stored) return { error: `${def.name} is not connected. Connect it in Settings → Connectors.` };

  if (def.authType === "token") {
    if (!stored.token) return { error: `${def.name} is not connected (no token saved).` };
    const h = def.tokenHeader ?? { name: "Authorization", prefix: "Bearer " };
    return { header: { [h.name]: `${h.prefix ?? ""}${stored.token}` } };
  }

  // oauth2
  const { refreshAccessTokenIfNeeded } = await import("./oauth.js");
  const refreshed = await refreshAccessTokenIfNeeded(id);
  if ("error" in refreshed) return refreshed;
  return { header: { Authorization: `Bearer ${refreshed.accessToken}` } };
}
