/**
 * Desktop server entrypoint.
 *
 * HTTP:
 *   GET  /health           -> { ok, name, version }
 *   POST /pair { code }    -> { token, serverName, serverVersion }
 *   GET  /metal/models     -> installed desktop Metal models (Bearer token)
 * WebSocket:
 *   /session?token=...     -> the agent protocol (see src/protocol.ts)
 *
 * Set APC_MOCK=1 to run the deterministic offline agent (no API key needed).
 *
 * This module exports `startServer(opts)` so both the headless CLI
 * (`npm start`) and the Electron shell (`npm run electron:dev`) can reuse
 * the same Express + WebSocket bootstrap.
 */
import http from "node:http";
import express from "express";
import { WebSocketServer, type WebSocket } from "ws";
import { PairingManager } from "./pairing.js";
import { SessionManager } from "./sessions.js";
import { parseClientMessage, encodeServerMessage, PairRequest, type ServerMessage } from "./protocol.js";
import { mockAdapter } from "./providers/index.js";
import { syncSkillsRepo, upsertSkill, removeSkill } from "./skills/sync.js";
import { syncMCPRepo, upsertMCPServer, removeMCPServer } from "./mcp/sync.js";
import { killTerminal, resizeTerminal, startTerminal, writeToTerminal } from "./terminal/index.js";
import { diffAgainstBase, listChanges, listDir, readFile, writeFile } from "./workspace/files.js";
import { listListeningPorts } from "./workspace/ports.js";
import { productDataDir } from "./product.js";
import {
  detectTunnelProviders,
  listTunnels,
  startTunnel,
  stopTunnel,
} from "./workspace/tunnels.js";
import {
  currentAccessTunnel,
  ensureAccessTunnel,
  stopAccessTunnel,
} from "./workspace/access-tunnel.js";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { advertiseServer, lanIPv4Addresses } from "./discovery.js";
import {
  loadDesktopPrefs,
  resolveAdvertise,
  resolveAutoTunnel,
} from "./desktop-config.js";
import {
  printPairingBanner,
  printTunnelReadyBanner,
  resolvePairHost,
} from "./cli/banner.js";
import { runSettingsMenu } from "./cli/settings-menu.js";
import { getMetalStore, getMetalRuntimeStatus, METAL_PROVIDER_ID } from "./metal/index.js";

export interface StartServerOptions {
  port?: number;
  host?: string;
  serverName?: string;
  version?: string;
  mock?: boolean;
  /** Suppress the "listening on …" + QR banner. The Electron shell shows its own UI. */
  silent?: boolean;
  /**
   * Advertise over Bonjour/mDNS on the LAN so phones can auto-discover this
   * server. Default true. Set false for smoke tests / headless CI.
   */
  advertise?: boolean;
  /**
   * After a phone pairs / opens a session, auto-start a public tunnel
   * (Cloudflare / ngrok / localtunnel) and push `remote_endpoint` so the app
   * can leave the LAN. Default true. Disable with APC_AUTO_TUNNEL=0.
   */
  autoTunnel?: boolean;
  /** Interactive CLI settings menu when stdin is a TTY (headless only). */
  cliSettings?: boolean;
  /** Called once the HTTP server is actually listening. */
  onReady?: (info: { port: number; host: string; pairingCode: string }) => void;
}

export interface RunningServer {
  port: number;
  host: string;
  pairingCode: string;
  /** Rotate the 6-digit pairing code (returns the new one). */
  rotatePairingCode: () => string;
  close: () => Promise<void>;
}

const DEFAULT_PORT = 4319;
/** Listen on all interfaces so LAN phones can pair (override with APC_HOST). */
const DEFAULT_HOST = "0.0.0.0";
const DEFAULT_NAME = process.env.APC_NAME ?? "CodeSocket desktop";
const DEFAULT_VERSION = "0.2.0";

/** Configured skills/MCP repos. Read once at startup. The desktop is the
 * git operator; both repos are user-configured in the desktop UI / env. */
interface SyncConfig {
  skillsRepo: { url: string; branch: string; token: string };
  mcpRepo: { url: string; branch: string; token: string };
  author: { name: string; email: string };
}

async function loadSyncConfig(): Promise<SyncConfig> {
  const file = path.join(productDataDir(), "config.json");
  let json: Partial<SyncConfig> = {};
  try {
    const raw = await fs.readFile(file, "utf8");
    json = JSON.parse(raw);
  } catch {
    // file doesn't exist yet — fall back to env vars
  }
  return {
    skillsRepo: {
      url: process.env.APC_SKILLS_REPO ?? json.skillsRepo?.url ?? "",
      branch: process.env.APC_SKILLS_BRANCH ?? json.skillsRepo?.branch ?? "main",
      token: process.env.APC_SKILLS_TOKEN ?? json.skillsRepo?.token ?? "",
    },
    mcpRepo: {
      url: process.env.APC_MCP_REPO ?? json.mcpRepo?.url ?? "",
      branch: process.env.APC_MCP_BRANCH ?? json.mcpRepo?.branch ?? "main",
      token: process.env.APC_MCP_TOKEN ?? json.mcpRepo?.token ?? "",
    },
    author: {
      name: process.env.APC_AUTHOR_NAME ?? json.author?.name ?? "CodeSocket",
      email: process.env.APC_AUTHOR_EMAIL ?? json.author?.email ?? "bot@codesocket.local",
    },
  };
}

/**
 * Start the HTTP + WebSocket server. Returns once it's listening.
 * `silent=true` skips the console banner (Electron renders its own UI).
 */
export async function startServer(opts: StartServerOptions = {}): Promise<RunningServer> {
  const desktopPrefs = loadDesktopPrefs();
  const port = opts.port ?? Number(process.env.PORT ?? DEFAULT_PORT);
  const host = opts.host ?? process.env.APC_HOST ?? DEFAULT_HOST;
  const serverName = opts.serverName ?? DEFAULT_NAME;
  const version = opts.version ?? DEFAULT_VERSION;
  const useMock = opts.mock ?? process.env.APC_MOCK === "1";
  const silent = opts.silent ?? false;
  const shouldAdvertise = resolveAdvertise(desktopPrefs, opts.advertise);
  const shouldAutoTunnel = resolveAutoTunnel(desktopPrefs, opts.autoTunnel);
  const tunnelProvider = desktopPrefs.tunnelProvider;
  const openCliSettings =
    opts.cliSettings ??
    (!silent && process.stdin.isTTY && process.env.APC_CLI_SETTINGS !== "0");

  const pairing = new PairingManager();
  const syncConfig = await loadSyncConfig();
  const app = express();
  app.use(express.json({ limit: "2mb" }));

  /** Filled after listen — used by pair + tunnel helpers. */
  let boundPort = 0;

  app.get("/health", (_req, res) => {
    const access = currentAccessTunnel();
    res.json({
      ok: true,
      name: serverName,
      version,
      publicUrl: access?.url,
      tunnelStatus: access?.status,
    });
  });

  /**
   * List Metal / MLX models installed on this desktop for the coding agent.
   * Auth: `Authorization: Bearer <pair token>` (same token as the WebSocket).
   * Phone coding pickers use this so they never offer phone-local weights that
   * may not match the desktop store.
   */
  app.get("/metal/models", async (req, res) => {
    const auth = req.header("authorization") ?? "";
    const bearer = auth.toLowerCase().startsWith("bearer ")
      ? auth.slice(7).trim()
      : (typeof req.query.token === "string" ? req.query.token : "");
    if (!pairing.verify(bearer)) {
      res.status(401).json({ error: "Unauthorized" });
      return;
    }
    try {
      const status = await getMetalRuntimeStatus();
      const models = getMetalStore().listDownloaded().map((m) => ({
        hubID: m.hubID,
        displayName: m.displayName,
        downloadedAt: m.downloadedAt,
      }));
      res.json({
        provider: METAL_PROVIDER_ID,
        runtimeReady: status.runtimeReady,
        supported: status.supported,
        detail: status.detail,
        models,
      });
    } catch (err) {
      res.status(500).json({ error: (err as Error).message });
    }
  });

  app.post("/pair", (req, res) => {
    const parsed = PairRequest.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "Invalid pair request." });
      return;
    }
    const device = pairing.pair(parsed.data.code, parsed.data.deviceName);
    if (!device) {
      res.status(401).json({ error: "Invalid pairing code." });
      return;
    }
    const access = currentAccessTunnel();
    res.json({
      token: device.token,
      serverName,
      serverVersion: version,
      publicUrl: access?.url,
    });
    // Re-read prefs so CLI/Electron toggles apply without restart.
    const livePrefs = loadDesktopPrefs();
    const autoTunnel = resolveAutoTunnel(livePrefs, opts.autoTunnel);
    // Kick a public tunnel so the phone can leave Wi‑Fi without re-pairing.
    if (autoTunnel && boundPort > 0) {
      void ensureAccessTunnel({ port: boundPort, provider: livePrefs.tunnelProvider }).then((info) =>
        announceAccessTunnel(info, {
          silent,
          pairingCode: () => pairing.pairingCode,
          context: "after pair",
        }),
      );
    }
    if (livePrefs.rotateCodeAfterPair) {
      const next = pairing.rotateCode();
      console.log(`[apc] pairing code rotated after pair → ${next}`);
    }
  });

  const server = http.createServer(app);
  const wss = new WebSocketServer({ server, path: "/session" });

  wss.on("connection", (ws: WebSocket, req) => {
    const url = new URL(req.url ?? "", "http://localhost");
    const token = url.searchParams.get("token");
    if (!pairing.verify(token)) {
      ws.close(4001, "Unauthorized");
      return;
    }

    const emit = (msg: ServerMessage) => {
      if (ws.readyState === ws.OPEN) ws.send(encodeServerMessage(msg));
    };
    const manager = new SessionManager(emit, useMock ? mockAdapter : undefined);

    // Auto-push the current skills/MCP state to the app on connect.
    void pushInitialSync(emit, syncConfig);

    // Start / report the coding-server public tunnel so the phone can upgrade
    // off the LAN while keeping this bearer token.
    {
      const live = loadDesktopPrefs();
      if (resolveAutoTunnel(live, opts.autoTunnel) && boundPort > 0) {
        void pushRemoteEndpoint(emit, boundPort, live.tunnelProvider, false, {
          silent,
          pairingCode: () => pairing.pairingCode,
        });
      }
    }

    ws.on("message", async (data) => {
      let msg;
      try {
        msg = parseClientMessage(data.toString());
      } catch (err) {
        emit({ type: "error", message: `Bad message: ${(err as Error).message}` });
        return;
      }
      try {
        switch (msg.type) {
          case "create_session":
            await manager.create(msg);
            break;
          case "user_message":
            await manager.handleUserMessage(msg.sessionId, msg.text, msg.model);
            break;
          case "permission_response":
            manager.resolvePermission(msg.sessionId, msg.requestId, msg.decision);
            break;
          case "interrupt":
            manager.interrupt(msg.sessionId);
            break;
          case "create_pr":
            await manager.createPr(msg);
            break;
          case "git_publish":
            await manager.gitPublish(msg);
            break;
          case "skills_sync_request":
            if (!syncConfig.skillsRepo.url) {
              emit({ type: "error", message: "No skills repo configured on the desktop." });
            } else {
              const skills = await syncSkillsRepo(syncConfig.skillsRepo, syncConfig.skillsRepo.token || undefined);
              emit({ type: "skills_sync", skills });
            }
            break;
          case "skill_upsert":
            if (!syncConfig.skillsRepo.url) {
              emit({ type: "error", message: "No skills repo configured on the desktop." });
            } else {
              await upsertSkill(msg.skill, syncConfig.skillsRepo, syncConfig.skillsRepo.token || undefined, syncConfig.author);
              const skills = await syncSkillsRepo(syncConfig.skillsRepo, syncConfig.skillsRepo.token || undefined);
              emit({ type: "skills_sync", skills });
            }
            break;
          case "skill_delete":
            if (!syncConfig.skillsRepo.url) {
              emit({ type: "error", message: "No skills repo configured on the desktop." });
            } else {
              await removeSkill(msg.id, syncConfig.skillsRepo, syncConfig.skillsRepo.token || undefined, syncConfig.author);
              const skills = await syncSkillsRepo(syncConfig.skillsRepo, syncConfig.skillsRepo.token || undefined);
              emit({ type: "skills_sync", skills });
            }
            break;
          case "mcp_sync_request":
            if (!syncConfig.mcpRepo.url) {
              emit({ type: "error", message: "No MCP repo configured on the desktop." });
            } else {
              const servers = await syncMCPRepo(syncConfig.mcpRepo, syncConfig.mcpRepo.token || undefined);
              emit({ type: "mcp_sync", servers });
            }
            break;
          case "mcp_upsert":
            if (!syncConfig.mcpRepo.url) {
              emit({ type: "error", message: "No MCP repo configured on the desktop." });
            } else {
              await upsertMCPServer(msg.server, syncConfig.mcpRepo, syncConfig.mcpRepo.token || undefined, syncConfig.author);
              const servers = await syncMCPRepo(syncConfig.mcpRepo, syncConfig.mcpRepo.token || undefined);
              emit({ type: "mcp_sync", servers });
            }
            break;
          case "mcp_delete":
            if (!syncConfig.mcpRepo.url) {
              emit({ type: "error", message: "No MCP repo configured on the desktop." });
            } else {
              await removeMCPServer(msg.id, syncConfig.mcpRepo, syncConfig.mcpRepo.token || undefined, syncConfig.author);
              const servers = await syncMCPRepo(syncConfig.mcpRepo, syncConfig.mcpRepo.token || undefined);
              emit({ type: "mcp_sync", servers });
            }
            break;
          case "terminal_open": {
            const workdir = manager.workdirFor(msg.sessionId);
            if (!workdir) {
              emit({ type: "error", sessionId: msg.sessionId, message: "Unknown session." });
              break;
            }
            startTerminal(workdir, ws);
            break;
          }
          case "terminal_input":
            writeToTerminal(msg.terminalId, msg.data);
            break;
          case "terminal_resize":
            resizeTerminal(msg.terminalId, msg.cols, msg.rows);
            break;
          case "terminal_kill":
            killTerminal(msg.terminalId);
            break;
          case "file_list": {
            const workdir = manager.workdirFor(msg.sessionId);
            if (!workdir) {
              emit({ type: "error", sessionId: msg.sessionId, message: "Unknown session." });
              break;
            }
            try {
              const entries = await listDir(workdir, msg.path);
              const atRoot = !msg.path || msg.path === "." || msg.path === "";
              const diff = atRoot ? await diffAgainstBase(workdir) : undefined;
              const changes = atRoot ? await listChanges(workdir) : undefined;
              emit({
                type: "file_list_result",
                sessionId: msg.sessionId,
                path: msg.path,
                entries,
                diff,
                changes,
              });
            } catch (err) {
              emit({ type: "error", sessionId: msg.sessionId, message: (err as Error).message });
            }
            break;
          }
          case "file_read": {
            const workdir = manager.workdirFor(msg.sessionId);
            if (!workdir) {
              emit({ type: "error", sessionId: msg.sessionId, message: "Unknown session." });
              break;
            }
            try {
              const { content, truncated, diff } = await readFile(workdir, msg.path);
              emit({
                type: "file_read_result",
                sessionId: msg.sessionId,
                path: msg.path,
                content,
                truncated,
                diff,
              });
            } catch (err) {
              emit({ type: "error", sessionId: msg.sessionId, message: (err as Error).message });
            }
            break;
          }
          case "file_write": {
            const workdir = manager.workdirFor(msg.sessionId);
            if (!workdir) {
              emit({ type: "error", sessionId: msg.sessionId, message: "Unknown session." });
              break;
            }
            try {
              await writeFile(workdir, msg.path, msg.content);
              emit({
                type: "file_write_result",
                sessionId: msg.sessionId,
                path: msg.path,
                ok: true,
                message: `Saved ${msg.path}`,
              });
            } catch (err) {
              emit({
                type: "file_write_result",
                sessionId: msg.sessionId,
                path: msg.path,
                ok: false,
                message: (err as Error).message,
              });
            }
            break;
          }
          case "port_list": {
            const workdir = manager.workdirFor(msg.sessionId);
            if (!workdir) {
              emit({ type: "error", sessionId: msg.sessionId, message: "Unknown session." });
              break;
            }
            const ports = await listListeningPorts();
            emit({ type: "port_list_result", sessionId: msg.sessionId, ports });
            break;
          }
          case "tunnel_start": {
            if (!manager.workdirFor(msg.sessionId)) {
              emit({ type: "error", sessionId: msg.sessionId, message: "Unknown session." });
              break;
            }
            try {
              await startTunnel({ port: msg.port, provider: msg.provider });
              const availableProviders = await detectTunnelProviders();
              emit({
                type: "tunnel_status",
                sessionId: msg.sessionId,
                tunnels: listTunnels(),
                availableProviders,
              });
            } catch (err) {
              emit({ type: "error", sessionId: msg.sessionId, message: (err as Error).message });
            }
            break;
          }
          case "tunnel_stop": {
            stopTunnel(msg.tunnelId);
            emit({
              type: "tunnel_status",
              sessionId: msg.sessionId,
              tunnels: listTunnels(),
              availableProviders: await detectTunnelProviders(),
            });
            break;
          }
          case "tunnel_list": {
            emit({
              type: "tunnel_status",
              sessionId: msg.sessionId,
              tunnels: listTunnels(),
              availableProviders: await detectTunnelProviders(),
            });
            break;
          }
          case "remote_endpoint_request": {
            // Phone fell back to LAN after a dead tunnel — (re)publish a public URL.
            if (boundPort <= 0) {
              emit({
                type: "remote_endpoint",
                status: "error",
                error: "Server is not listening yet.",
              });
              break;
            }
            const live = loadDesktopPrefs();
            void pushRemoteEndpoint(
              emit,
              boundPort,
              live.tunnelProvider,
              Boolean(msg.force),
              {
                silent,
                pairingCode: () => pairing.pairingCode,
              },
            );
            break;
          }
        }
      } catch (err) {
        emit({ type: "error", message: (err as Error).message });
      }
    });
  });

  await new Promise<void>((resolve, reject) => {
    const onError = (err: NodeJS.ErrnoException) => {
      server.off("error", onError);
      if (err.code === "EADDRINUSE") {
        reject(
          new Error(
            `Port ${port} is already in use. Quit the other CodeSocket / desktop-server process, or set PORT to a free port.`,
          ),
        );
        return;
      }
      reject(err);
    };
    server.once("error", onError);
    server.listen(port, host, () => {
      server.off("error", onError);
      resolve();
    });
  });

  boundPort = (server.address() as { port: number } | null)?.port ?? port;
  const pairingCode = pairing.pairingCode;

  const advertisement = advertiseServer({
    name: serverName,
    port: boundPort,
    version,
    enabled: shouldAdvertise,
  });

  if (!silent) {
    const existingTunnel =
      currentAccessTunnel()?.url || desktopPrefs.remoteAccessUrl.trim() || null;
    if (desktopPrefs.showPairingCodePopup) {
      await printPairingBanner({
        serverName,
        version,
        host,
        port: boundPort,
        pairingCode,
        mock: useMock,
        advertise: shouldAdvertise,
        autoTunnel: shouldAutoTunnel,
        publicUrl: existingTunnel,
      });
    } else {
      const lan = lanIPv4Addresses();
      console.log(`\n${serverName} v${version} listening on http://${host}:${boundPort}`);
      if (lan.length > 0) {
        console.log(`LAN: ${lan.map((ip) => `http://${ip}:${boundPort}`).join(", ")}`);
      }
      if (existingTunnel) {
        console.log(`Tunnel URL: ${existingTunnel}`);
      }
      console.log(`Pairing code: ${pairingCode}${useMock ? "  (MOCK agent)" : ""}`);
    }
    if (openCliSettings) {
      console.log("CLI settings: type a command at the prompt (h = help, q = leave menu).\n");
      void runSettingsMenu({
        getPairingCode: () => pairing.pairingCode,
        getPairHost: () =>
          resolvePairHost(host, boundPort, currentAccessTunnel()?.url ?? null),
        rotateCode: () => pairing.rotateCode(),
        getServerInfo: () => ({ host, port: boundPort, name: serverName }),
      });
    }
  }

  // Always-on remote tunnel (Electron remote access / prefs) — start at boot
  // and print the public URL + QR when the tunnel finishes loading.
  if (desktopPrefs.remoteAccessEnabled && boundPort > 0) {
    if (!silent) {
      console.log("[apc] remote access enabled — starting public tunnel…");
    }
    void ensureAccessTunnel({ port: boundPort, provider: tunnelProvider }).then((info) =>
      announceAccessTunnel(info, {
        silent,
        pairingCode: () => pairing.pairingCode,
        context: "remote access",
      }),
    );
  }

  opts.onReady?.({ port: boundPort, host, pairingCode });

  return {
    port: boundPort,
    host,
    get pairingCode() {
      return pairing.pairingCode;
    },
    rotatePairingCode: () => pairing.rotateCode(),
    close: async () => {
      stopAccessTunnel();
      await advertisement.stop();
      await new Promise<void>((resolve) => wss.close(() => resolve()));
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

/**
 * Terminal + log announcement when the coding-server access tunnel is up.
 * Non-silent mode reprints the pairing QR with the public HTTPS host so
 * phones scan the tunnel URL instead of a LAN address.
 */
async function announceAccessTunnel(
  info: { url?: string; provider: string; status: string; error?: string },
  opts: {
    silent: boolean;
    pairingCode: () => string;
    context?: string;
  },
): Promise<void> {
  const ctx = opts.context ? ` ${opts.context}` : "";
  if (info.url && (info.status === "up" || info.status === "starting")) {
    if (!opts.silent) {
      await printTunnelReadyBanner({
        url: info.url,
        provider: info.provider,
        pairingCode: opts.pairingCode(),
      });
    } else {
      console.log(`[apc] access tunnel ready${ctx}: ${info.url} (${info.provider})`);
    }
    return;
  }
  if (info.status === "error") {
    console.warn(`[apc] access tunnel failed${ctx}: ${info.error ?? info.status}`);
  }
}

/** Start the coding-server tunnel and push status frames to one WebSocket. */
async function pushRemoteEndpoint(
  emit: (msg: ServerMessage) => void,
  port: number,
  provider: "auto" | "ngrok" | "cloudflare" | "localtunnel" | "bore" = "auto",
  force = false,
  announce?: {
    silent: boolean;
    pairingCode: () => string;
  },
): Promise<void> {
  const existing = currentAccessTunnel();
  if (!force && existing?.url && existing.status === "up") {
    emit({
      type: "remote_endpoint",
      status: "up",
      url: existing.url,
      provider: existing.provider,
    });
    return;
  }

  emit({
    type: "remote_endpoint",
    status: "starting",
    provider: existing?.provider ?? provider,
  });

  try {
    const info = await ensureAccessTunnel({ port, provider, force });
    if (info.url && (info.status === "up" || info.status === "starting")) {
      emit({
        type: "remote_endpoint",
        status: "up",
        url: info.url,
        provider: info.provider,
      });
      if (announce) {
        await announceAccessTunnel(info, {
          silent: announce.silent,
          pairingCode: announce.pairingCode,
          context: force ? "remote_endpoint [forced]" : "remote_endpoint",
        });
      } else {
        console.log(
          `[apc] remote_endpoint → ${info.url} (${info.provider})${force ? " [forced]" : ""}`,
        );
      }
    } else {
      emit({
        type: "remote_endpoint",
        status: "error",
        provider: info.provider,
        error: info.error ?? "Could not obtain a public tunnel URL.",
      });
      console.warn(`[apc] remote_endpoint failed: ${info.error ?? info.status}`);
    }
  } catch (err) {
    emit({
      type: "remote_endpoint",
      status: "error",
      error: (err as Error).message,
    });
    console.warn(`[apc] remote_endpoint error: ${(err as Error).message}`);
  }
}

/**
 * Push the current skills + MCP state to a freshly-connected app. Both
 * repos are optional (the user may not have configured either yet), and
 * missing-config errors are surfaced to the client as `error` messages
 * rather than throwing.
 */
async function pushInitialSync(
  emit: (msg: ServerMessage) => void,
  cfg: SyncConfig,
): Promise<void> {
  if (cfg.skillsRepo.url) {
    try {
      const skills = await syncSkillsRepo(cfg.skillsRepo, cfg.skillsRepo.token || undefined);
      emit({ type: "skills_sync", skills });
    } catch (err) {
      emit({ type: "error", message: `Skills sync failed: ${(err as Error).message}` });
    }
  }
  if (cfg.mcpRepo.url) {
    try {
      const servers = await syncMCPRepo(cfg.mcpRepo, cfg.mcpRepo.token || undefined);
      emit({ type: "mcp_sync", servers });
    } catch (err) {
      emit({ type: "error", message: `MCP sync failed: ${(err as Error).message}` });
    }
  }
}

// Headless CLI mode: when this file is invoked directly (`node dist/src/index.js`
// or `tsx src/index.ts`).
const isDirectInvocation =
  // ESM equivalent of `require.main === module`
  import.meta.url === `file://${process.argv[1]}` ||
  process.argv[1]?.endsWith("index.js") ||
  process.argv[1]?.endsWith("index.ts");

if (isDirectInvocation) {
  startServer().catch((err) => {
    console.error("Failed to start server:", err);
    process.exit(1);
  });
}
