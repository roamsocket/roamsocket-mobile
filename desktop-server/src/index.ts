/**
 * Desktop server entrypoint.
 *
 * HTTP:
 *   GET  /health           -> { ok, name, version }
 *   POST /pair { code }    -> { token, serverName, serverVersion }
 * WebSocket:
 *   /session?token=...     -> the agent protocol (see src/protocol.ts)
 *
 * Set CMAI_MOCK=1 to run the deterministic offline agent (no API key needed).
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
import { diffAgainstBase, listDir, readFile } from "./workspace/files.js";
import { listListeningPorts } from "./workspace/ports.js";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

export interface StartServerOptions {
  port?: number;
  host?: string;
  serverName?: string;
  version?: string;
  mock?: boolean;
  /** Suppress the "listening on …" + QR banner. The Electron shell shows its own UI. */
  silent?: boolean;
  /** Called once the HTTP server is actually listening. */
  onReady?: (info: { port: number; host: string; pairingCode: string }) => void;
}

export interface RunningServer {
  port: number;
  host: string;
  pairingCode: string;
  close: () => Promise<void>;
}

const DEFAULT_PORT = 4319;
const DEFAULT_NAME = process.env.CMAI_NAME ?? "code-mobile-ai desktop";
const DEFAULT_VERSION = "0.2.0";

/** Configured skills/MCP repos. Read once at startup. The desktop is the
 * git operator; both repos are user-configured in the desktop UI / env. */
interface SyncConfig {
  skillsRepo: { url: string; branch: string; token: string };
  mcpRepo: { url: string; branch: string; token: string };
  author: { name: string; email: string };
}

async function loadSyncConfig(): Promise<SyncConfig> {
  const home = os.homedir();
  const file = path.join(home, ".code-mobile-ai", "config.json");
  let json: Partial<SyncConfig> = {};
  try {
    const raw = await fs.readFile(file, "utf8");
    json = JSON.parse(raw);
  } catch {
    // file doesn't exist yet — fall back to env vars
  }
  return {
    skillsRepo: {
      url: process.env.CMAI_SKILLS_REPO ?? json.skillsRepo?.url ?? "",
      branch: process.env.CMAI_SKILLS_BRANCH ?? json.skillsRepo?.branch ?? "main",
      token: process.env.CMAI_SKILLS_TOKEN ?? json.skillsRepo?.token ?? "",
    },
    mcpRepo: {
      url: process.env.CMAI_MCP_REPO ?? json.mcpRepo?.url ?? "",
      branch: process.env.CMAI_MCP_BRANCH ?? json.mcpRepo?.branch ?? "main",
      token: process.env.CMAI_MCP_TOKEN ?? json.mcpRepo?.token ?? "",
    },
    author: {
      name: process.env.CMAI_AUTHOR_NAME ?? json.author?.name ?? "code-mobile-ai",
      email: process.env.CMAI_AUTHOR_EMAIL ?? json.author?.email ?? "bot@code-mobile-ai.local",
    },
  };
}

/**
 * Start the HTTP + WebSocket server. Returns once it's listening.
 * `silent=true` skips the console banner (Electron renders its own UI).
 */
export async function startServer(opts: StartServerOptions = {}): Promise<RunningServer> {
  const port = opts.port ?? Number(process.env.PORT ?? DEFAULT_PORT);
  const host = opts.host ?? process.env.CMAI_HOST ?? "127.0.0.1";
  const serverName = opts.serverName ?? DEFAULT_NAME;
  const version = opts.version ?? DEFAULT_VERSION;
  const useMock = opts.mock ?? process.env.CMAI_MOCK === "1";
  const silent = opts.silent ?? false;

  const pairing = new PairingManager();
  const syncConfig = await loadSyncConfig();
  const app = express();
  app.use(express.json({ limit: "2mb" }));

  app.get("/health", (_req, res) => {
    res.json({ ok: true, name: serverName, version });
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
    res.json({ token: device.token, serverName, serverVersion: version });
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
            await manager.handleUserMessage(msg.sessionId, msg.text);
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
              const diff = msg.path === "" ? await diffAgainstBase(workdir) : undefined;
              emit({ type: "file_list_result", sessionId: msg.sessionId, path: msg.path, entries, diff });
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
              const { content, truncated } = await readFile(workdir, msg.path);
              emit({
                type: "file_read_result",
                sessionId: msg.sessionId,
                path: msg.path,
                content,
                truncated,
              });
            } catch (err) {
              emit({ type: "error", sessionId: msg.sessionId, message: (err as Error).message });
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
        }
      } catch (err) {
        emit({ type: "error", message: (err as Error).message });
      }
    });
  });

  await new Promise<void>((resolve) => {
    server.listen(port, host, () => resolve());
  });

  const boundPort = (server.address() as { port: number } | null)?.port ?? port;
  const pairingCode = pairing.pairingCode;

  if (!silent) {
    const payload = JSON.stringify({ host: `http://${host}:${boundPort}`, code: pairingCode });
    console.log(`\n${serverName} v${version} listening on http://${host}:${boundPort}`);
    console.log(`Pairing code: ${pairingCode}${useMock ? "  (MOCK agent)" : ""}`);
    console.log(`Pair payload: ${payload}`);
    console.log("(Tip: paste the JSON payload into any QR generator to make a scannable code.)");
  }

  opts.onReady?.({ port: boundPort, host, pairingCode });

  return {
    port: boundPort,
    host,
    pairingCode,
    close: async () => {
      await new Promise<void>((resolve) => wss.close(() => resolve()));
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
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
