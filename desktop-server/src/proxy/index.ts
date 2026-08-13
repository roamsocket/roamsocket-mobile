/**
 * Pass-through OpenAI- and Anthropic-compatible proxy.
 *
 * The desktop is the user's single source of truth for provider API keys.
 * External coding CLIs (Codex, Claude Code, Aider, Cursor CLI, OpenCode, …)
 * can point at `http://localhost:4319/v1` and use the desktop's keys without
 * the user having to configure each tool individually.
 *
 * Design goals:
 * - Tiny. We don't reimplement wire formats — we forward requests as-is to
 *   the configured upstream, inject the right `Authorization` / `x-api-key`
 *   header from the desktop's key store, and stream the response back.
 * - No agent loop on this path. Tools that want tool-use get real provider
 *   tool calls (Codex/Aider/OpenCode already speak that natively). The
 *   desktop's normalized `agent/loop.ts` still powers the iOS app and the
 *   legacy TUI.
 * - Bearer-auth: either the desktop's pairing token (same one iOS uses) or
 *   a stable `APC_PROXY_TOKEN` env var so external CLIs don't have to pair.
 *
 * Auth resolution (per request):
 *   1. APC_PROXY_TOKEN env var (if set, accepts any non-empty value as a
 *      shared secret — useful for scripted use; no per-call pairing needed).
 *   2. A valid desktop pairing bearer token (the same one `/session` uses).
 *
 * Provider selection per request:
 *   - `X-RoamSocket-Provider: <id>` header (preferred — Codex sends base URL
 *     only, so this lets one proxy URL cover all providers).
 *   - Anthropic-style requests auto-detect `anthropic` by path/messages shape.
 *   - Otherwise fall back to the desktop's last-selected provider (APC_PROXY_PROVIDER).
 */
import express from "express";
import type { ProviderId } from "../protocol.js";
import {
  readStoredApiKey,
  resolveProxyApiKey,
} from "./keys.js";

/** Upstream base URLs for the providers we proxy out of the box. */
export const PROXY_UPSTREAM: Record<string, { base: string; style: "openai" | "anthropic" }> = {
  openai:      { base: "https://api.openai.com/v1",       style: "openai" },
  anthropic:   { base: "https://api.anthropic.com/v1",    style: "anthropic" },
  groq:        { base: "https://api.groq.com/openai/v1",   style: "openai" },
  openrouter:  { base: "https://openrouter.ai/api/v1",     style: "openai" },
  xai:         { base: "https://api.x.ai/v1",              style: "openai" },
  mistral:     { base: "https://api.mistral.ai/v1",        style: "openai" },
  minimax:     { base: "https://api.minimax.io/v1",        style: "openai" },
};

/** Headers we strip before forwarding (avoid leaking hop-by-hop / auth). */
const HOP_BY_HOP = new Set([
  "host",
  "content-length",
  "connection",
  "keep-alive",
  "transfer-encoding",
  "te",
  "trailer",
  "upgrade",
  "authorization",
  "x-api-key",
  "x-roamsocket-provider",
]);

export interface ProxyDeps {
  /**
   * Verify a desktop pairing bearer token. Returns truthy if valid.
   * Reuse the existing PairingManager so the same token list works for
   * `/session`, `/metal/models`, and `/v1/*`.
   */
  verifyPairToken: (token: string | null | undefined) => boolean | unknown;
  /**
   * Verify the static APC_PROXY_TOKEN bearer (or any token the operator
   * pinned via env). Distinct from pairing tokens because it's set once
   * per process and shared across all external tools.
   */
  verifyProxyToken: (token: string | null | undefined) => boolean;
  /** Optional callback fired once per request (used for the access log). */
  onRequest?: (info: { provider: string; path: string; status: number }) => void;
}

/**
 * Pick the provider for an inbound request. Falls back through several
 * signals so external tools don't have to set anything beyond their base URL.
 */
function pickProvider(
  req: express.Request,
  providerHint?: string,
): ProviderId | null {
  const header = (req.header("x-roamsocket-provider") ?? "").trim();
  if (header) return header;
  if (providerHint) return providerHint;
  const env = (process.env.APC_PROXY_PROVIDER ?? "").trim();
  if (env) return env;
  // Anthropic requests are recognizable: `/v1/messages` and (usually) an
  // `anthropic-version` header. Without that hint, we can't tell OpenRouter
  // / Groq / OpenAI apart, so we require the user to set one of the above.
  if (req.path.endsWith("/v1/messages") || req.header("anthropic-version")) {
    return "anthropic";
  }
  return null;
}

function authenticate(
  req: express.Request,
  deps: ProxyDeps,
): boolean {
  const auth = req.header("authorization") ?? "";
  const bearer = auth.toLowerCase().startsWith("bearer ")
    ? auth.slice(7).trim()
    : "";
  const xApiKey = (req.header("x-api-key") ?? "").trim();
  // Accept either the process-scoped proxy token (APC_PROXY_TOKEN env or
  // the random one minted in `startServer`) or a valid pairing token. This
  // lets the iOS app and external tools share the same host.
  if (bearer && deps.verifyProxyToken(bearer)) return true;
  if (xApiKey && deps.verifyProxyToken(xApiKey)) return true;
  if (bearer && deps.verifyPairToken(bearer)) return true;
  return false;
}

function buildUpstreamHeaders(
  req: express.Request,
  provider: ProviderId,
  apiKey: string,
): Headers {
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) {
    if (v === undefined) continue;
    const lk = k.toLowerCase();
    if (HOP_BY_HOP.has(lk)) continue;
    if (Array.isArray(v)) headers.set(lk, v.join(", "));
    else headers.set(lk, String(v));
  }
  // Inject the real provider auth header.
  if (provider === "anthropic") {
    headers.set("x-api-key", apiKey);
    headers.set("anthropic-version", headers.get("anthropic-version") ?? "2023-06-01");
  } else {
    headers.set("authorization", `Bearer ${apiKey}`);
  }
  return headers;
}

async function readBody(req: express.Request): Promise<Buffer> {
  // Streams the request body as raw bytes. Express's `express.json()` global
  // parser would consume the stream and we'd see nothing here, so we read
  // it ourselves. The proxy routes must be registered *before* the global
  // JSON parser to avoid that race — `mountProxy` does exactly that.
  if (Buffer.isBuffer((req as unknown as { body?: unknown }).body)) {
    return (req as unknown as { body: Buffer }).body;
  }
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}

/**
 * Forward a single request to the upstream provider. Streams the response
 * back byte-for-byte so SSE / tool-call streaming works untouched.
 */
async function forward(
  req: express.Request,
  res: express.Response,
  provider: ProviderId,
  upstreamPath: string,
  deps: ProxyDeps,
): Promise<void> {
  const log = (status: number) => deps.onRequest?.({ provider, path: upstreamPath, status });
  if (!authenticate(req, deps)) {
    res.status(401).json({ error: "Unauthorized — pass the pairing bearer token, the APC_PROXY_TOKEN shared secret, or set X-RoamSocket-Provider + a stored key." });
    log(401);
    return;
  }

  const apiKey = resolveProxyApiKey(provider) ?? readStoredApiKey(provider);
  if (!apiKey) {
    res.status(401).json({
      error: `No API key available for provider "${provider}". Set ${provider.toUpperCase()}_API_KEY, save one with /keys, or store one via the desktop.`,
    });
    log(401);
    return;
  }

  const upstream = PROXY_UPSTREAM[provider];
  if (!upstream) {
    res.status(400).json({
      error: `Unknown provider "${provider}". Known: ${Object.keys(PROXY_UPSTREAM).join(", ")} (or set X-RoamSocket-Provider).`,
    });
    log(400);
    return;
  }

  const url = `${upstream.base}${upstreamPath}${req.url.includes("?") ? req.url.slice(req.url.indexOf("?")) : ""}`;
  const headers = buildUpstreamHeaders(req, provider, apiKey);
  const body = await readBody(req);

  let upstreamRes: Response;
  try {
    const fetchInit: RequestInit = {
      method: req.method,
      headers,
    };
    if (req.method !== "GET" && req.method !== "HEAD" && body.length > 0) {
      // Buffer is a Uint8Array subclass and runtime-fetch accepts it, but
      // the DOM lib doesn't expose Buffer as BodyInit. Cast through unknown
      // so both server (no DOM lib) and Electron (DOM lib) tsconfigs typecheck.
      fetchInit.body = new Uint8Array(body.buffer, body.byteOffset, body.byteLength) as unknown as RequestInit["body"];
    }
    upstreamRes = await fetch(url, fetchInit);
  } catch (err) {
    res.status(502).json({ error: `Upstream fetch failed: ${(err as Error).message}` });
    log(502);
    return;
  }

  // Copy status + headers (filter hop-by-hop and content-encoding: we
  // stream the raw body, so we don't want express to re-decode it).
  res.status(upstreamRes.status);
  upstreamRes.headers.forEach((value, key) => {
    const lk = key.toLowerCase();
    if (lk === "content-encoding" || lk === "content-length" || lk === "transfer-encoding" || lk === "connection") return;
    res.setHeader(key, value);
  });
  if (!res.getHeader("content-type")) {
    res.setHeader("content-type", upstreamRes.headers.get("content-type") ?? "application/json");
  }

  if (!upstreamRes.body) {
    res.end();
    log(upstreamRes.status);
    return;
  }

  const reader = upstreamRes.body.getReader();
  // Don't auto-close on req abort — abort the upstream fetch instead so the
  // client gets a clean cancel rather than a half-streamed response.
  const abort = new AbortController();
  req.on("aborted", () => abort.abort());
  res.on("close", () => {
    if (!res.writableEnded) abort.abort();
  });
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (abort.signal.aborted) break;
      if (!res.write(Buffer.from(value))) {
        // Backpressure: wait for drain before reading more.
        await new Promise<void>((resolve) => res.once("drain", resolve));
      }
    }
  } catch (err) {
    if (!abort.signal.aborted) {
      console.warn(`[proxy] upstream stream error (${provider} ${upstreamPath}): ${(err as Error).message}`);
    }
  } finally {
    res.end();
    log(upstreamRes.status);
  }
}

/**
 * Mount the proxy routes on the given express app.
 * Routes:
 *   GET  /v1/models                      OpenAI-shaped model list
 *   POST /v1/chat/completions            OpenAI-shaped, pass-through
 *   POST /v1/completions                 legacy OpenAI, pass-through
 *   POST /v1/messages                    Anthropic-shaped, pass-through
 *   GET  /v1/models/:anything            pass-through (provider-specific)
 *   ANY  /v1/<anything>                  catch-all pass-through
 */
export function mountProxy(app: express.Express, deps: ProxyDeps): void {
  // OpenAI-shaped model list. Synthesized from PROXY_UPSTREAM + anything the
  // user has a key for, so tools that introspect /v1/models get a real list.
  app.get("/v1/models", (req, res) => {
    if (!authenticate(req, deps)) {
      res.status(401).json({ error: "Unauthorized" });
      return;
    }
    const now = Math.floor(Date.now() / 1000);
    const data = Object.keys(PROXY_UPSTREAM).map((id) => ({
      id: `${id}/`,
      object: "model",
      created: now,
      owned_by: id,
    }));
    res.json({ object: "list", data });
  });

  // Body is read as a raw stream in `forward()` so SSE / non-JSON shapes
  // pass through untouched. The host's global JSON parser is skipped for
  // `/v1/*` to avoid the stream being consumed before we get to it.

  app.post("/v1/chat/completions", (req, res) => {
    const provider = pickProvider(req);
    if (!provider) {
      res.status(400).json({ error: "Missing provider — set X-RoamSocket-Provider or APC_PROXY_PROVIDER." });
      return;
    }
    void forward(req, res, provider, "/chat/completions", deps);
  });

  app.post("/v1/completions", (req, res) => {
    const provider = pickProvider(req);
    if (!provider) {
      res.status(400).json({ error: "Missing provider — set X-RoamSocket-Provider or APC_PROXY_PROVIDER." });
      return;
    }
    void forward(req, res, provider, "/completions", deps);
  });

  app.post("/v1/messages", (req, res) => {
    const provider = pickProvider(req, "anthropic");
    if (!provider) {
      res.status(400).json({ error: "Anthropic provider unavailable — set ANTHROPIC_API_KEY." });
      return;
    }
    void forward(req, res, provider, "/messages", deps);
  });

  // Catch-all: forward any other /v1/* path the chosen provider supports.
  // Lets future endpoints (images, audio, embeddings, files) work without
  // us having to add a route per shape.
  app.all(/^\/v1\/.*/, (req, res) => {
    const provider = pickProvider(req);
    if (!provider) {
      res.status(400).json({ error: "Missing provider — set X-RoamSocket-Provider or APC_PROXY_PROVIDER." });
      return;
    }
    // Strip the leading /v1 so we append it to the upstream base uniformly.
    const tail = req.path.startsWith("/v1/") ? req.path.slice(3) : req.path.slice(3);
    void forward(req, res, provider, `/${tail}`, deps);
  });
}