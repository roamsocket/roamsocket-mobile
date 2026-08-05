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

    ws.on("message", async (data) => {
      let msg;
      try {
        msg = parseClientMessage(data.toString());
      } catch (err) {
        emit({ type: "error", message: `Bad message: ${(err as Error).message}` });
        return;
      }
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
