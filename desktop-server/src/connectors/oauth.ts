/**
 * Generic OAuth2 Authorization Code + PKCE flow for BYO-OAuth-app connectors
 * (Gmail, Google Calendar, Google Drive, …). The user supplies their own
 * client id (and optional secret) — RoamSocket does not ship a shared OAuth
 * client for any provider.
 *
 * Flow: build an authorize URL with a loopback redirect
 * (`http://127.0.0.1:<port>/callback`), open it in the system browser on
 * *this* machine, run a tiny local HTTP server to catch the redirect, then
 * exchange the code for tokens. This mirrors what Google's own "Desktop app"
 * OAuth client type expects (loopback IP redirect, no fixed port required).
 */
import crypto from "node:crypto";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { connectorDefinition } from "./catalog.js";
import { getStoredConnector, upsertStoredConnector } from "./store.js";
import { openInBrowser } from "./open-url.js";

const FLOW_TIMEOUT_MS = 5 * 60 * 1000;

function base64url(input: Buffer): string {
  return input.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function makePkce(): { verifier: string; challenge: string } {
  const verifier = base64url(crypto.randomBytes(32));
  const challenge = base64url(crypto.createHash("sha256").update(verifier).digest());
  return { verifier, challenge };
}

/**
 * Start an OAuth2 flow for `id`. Resolves once the flow either completes
 * (tokens stored) or fails/times out. Returns the authorize URL immediately
 * (before the promise settles) via the `onUrl` callback so the caller can
 * report it to the app right away, while the local callback server keeps
 * running in the background.
 */
export async function startOAuthFlow(
  id: string,
  onUrl: (url: string) => void,
): Promise<{ ok: true } | { error: string }> {
  const def = connectorDefinition(id);
  if (!def || def.authType !== "oauth2" || !def.oauth) {
    return { error: `${id} is not an OAuth2 connector.` };
  }
  const stored = getStoredConnector(id);
  if (!stored?.clientId) {
    return {
      error: `Add your OAuth app's Client ID for ${def.name} first (Settings → Connectors → ${def.name}).`,
    };
  }

  const { verifier, challenge } = makePkce();
  const state = base64url(crypto.randomBytes(16));

  return new Promise((resolve) => {
    let settled = false;
    const finish = (result: { ok: true } | { error: string }) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      server.close();
      resolve(result);
    };

    const server = http.createServer((req, res) => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      if (url.pathname !== "/callback") {
        res.writeHead(404).end();
        return;
      }
      const returnedState = url.searchParams.get("state");
      const code = url.searchParams.get("code");
      const oauthError = url.searchParams.get("error");
      res.writeHead(200, { "Content-Type": "text/html" });
      if (oauthError) {
        res.end(`<html><body>Connection failed: ${escapeHtml(oauthError)}. You can close this tab.</body></html>`);
        finish({ error: `${def.name} denied access: ${oauthError}` });
        return;
      }
      if (returnedState !== state || !code) {
        res.end("<html><body>Invalid response. You can close this tab.</body></html>");
        finish({ error: `${def.name} sign-in returned an unexpected response.` });
        return;
      }
      res.end(`<html><body>Connected to ${escapeHtml(def.name)}! You can close this tab and return to RoamSocket.</body></html>`);

      // Exchange the code for tokens.
      void exchangeCode(id, code, verifier).then((exchanged) => {
        finish(exchanged);
      });
    });

    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as AddressInfo;
      const redirectUri = `http://127.0.0.1:${port}/callback`;
      const authorize = new URL(def.oauth!.authUrl);
      authorize.searchParams.set("client_id", stored.clientId!);
      authorize.searchParams.set("redirect_uri", redirectUri);
      authorize.searchParams.set("response_type", "code");
      authorize.searchParams.set("scope", def.oauth!.scope);
      authorize.searchParams.set("state", state);
      authorize.searchParams.set("code_challenge", challenge);
      authorize.searchParams.set("code_challenge_method", "S256");
      // Ask Google-style providers for a refresh token on every consent.
      authorize.searchParams.set("access_type", "offline");
      authorize.searchParams.set("prompt", "consent");

      // Stash the redirect uri for the token exchange (must match exactly).
      pendingRedirectUris.set(id, redirectUri);

      onUrl(authorize.toString());
      void openInBrowser(authorize.toString());
    });

    const timer = setTimeout(() => {
      finish({ error: `Timed out waiting for ${def.name} sign-in.` });
    }, FLOW_TIMEOUT_MS);
  });
}

/** Redirect URI used for the in-flight authorize request (keyed by connector id). */
const pendingRedirectUris = new Map<string, string>();

async function exchangeCode(
  id: string,
  code: string,
  verifier: string,
): Promise<{ ok: true } | { error: string }> {
  const def = connectorDefinition(id);
  const stored = getStoredConnector(id);
  const redirectUri = pendingRedirectUris.get(id);
  if (!def?.oauth || !stored?.clientId || !redirectUri) {
    return { error: "OAuth flow state was lost — try connecting again." };
  }
  pendingRedirectUris.delete(id);

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: redirectUri,
    client_id: stored.clientId,
    code_verifier: verifier,
  });
  if (stored.clientSecret) body.set("client_secret", stored.clientSecret);

  try {
    const res = await fetch(def.oauth.tokenUrl, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
    const json = (await res.json().catch(() => ({}))) as {
      access_token?: string;
      refresh_token?: string;
      expires_in?: number;
      error?: string;
      error_description?: string;
    };
    if (!res.ok || !json.access_token) {
      const msg = json.error_description ?? json.error ?? `HTTP ${res.status}`;
      upsertStoredConnector(id, { lastError: msg });
      return { error: `${def.name} token exchange failed: ${msg}` };
    }
    upsertStoredConnector(id, {
      accessToken: json.access_token,
      refreshToken: json.refresh_token ?? stored.refreshToken,
      expiresAt: json.expires_in ? Date.now() + json.expires_in * 1000 : undefined,
      lastError: undefined,
    });
    return { ok: true };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    upsertStoredConnector(id, { lastError: msg });
    return { error: `${def.name} token exchange failed: ${msg}` };
  }
}

/** Refresh the access token if it's missing/expired and a refresh token exists. */
export async function refreshAccessTokenIfNeeded(
  id: string,
): Promise<{ accessToken: string } | { error: string }> {
  const def = connectorDefinition(id);
  const stored = getStoredConnector(id);
  if (!def?.oauth || !stored) return { error: `${id} is not connected.` };

  const stillValid = stored.accessToken && (!stored.expiresAt || stored.expiresAt > Date.now() + 30_000);
  if (stillValid) return { accessToken: stored.accessToken! };

  if (!stored.refreshToken || !stored.clientId) {
    return { error: `${def.name}'s connection expired. Reconnect it in Settings → Connectors.` };
  }

  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: stored.refreshToken,
    client_id: stored.clientId,
  });
  if (stored.clientSecret) body.set("client_secret", stored.clientSecret);

  try {
    const res = await fetch(def.oauth.tokenUrl, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
    const json = (await res.json().catch(() => ({}))) as {
      access_token?: string;
      expires_in?: number;
      error?: string;
      error_description?: string;
    };
    if (!res.ok || !json.access_token) {
      const msg = json.error_description ?? json.error ?? `HTTP ${res.status}`;
      return { error: `${def.name} refresh failed: ${msg}` };
    }
    upsertStoredConnector(id, {
      accessToken: json.access_token,
      expiresAt: json.expires_in ? Date.now() + json.expires_in * 1000 : undefined,
      lastError: undefined,
    });
    return { accessToken: json.access_token };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { error: `${def.name} refresh failed: ${msg}` };
  }
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
