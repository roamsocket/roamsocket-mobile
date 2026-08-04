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
 */
import http from "node:http";
import express from "express";
import { WebSocketServer, type WebSocket } from "ws";
import qrcode from "qrcode-terminal";
import { PairingManager } from "./pairing.js";
import { SessionManager } from "./sessions.js";
import { parseClientMessage, encodeServerMessage, PairRequest, type ServerMessage } from "./protocol.js";
import { mockAdapter } from "./providers/index.js";

const PORT = Number(process.env.PORT ?? 4319);
const SERVER_NAME = process.env.CMAI_NAME ?? "code-mobile-ai desktop";
const VERSION = "0.1.0";
const USE_MOCK = process.env.CMAI_MOCK === "1";

const pairing = new PairingManager();
const app = express();
app.use(express.json({ limit: "2mb" }));

app.get("/health", (_req, res) => {
  res.json({ ok: true, name: SERVER_NAME, version: VERSION });
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
  res.json({ token: device.token, serverName: SERVER_NAME, serverVersion: VERSION });
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
  const manager = new SessionManager(emit, USE_MOCK ? mockAdapter : undefined);

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

server.listen(PORT, () => {
  const code = pairing.pairingCode;
  const payload = JSON.stringify({ host: `http://localhost:${PORT}`, code });
  console.log(`\n${SERVER_NAME} v${VERSION} listening on http://localhost:${PORT}`);
  console.log(`Pairing code: ${code}${USE_MOCK ? "  (MOCK agent)" : ""}`);
  console.log("Scan to pair (host + code):");
  qrcode.generate(payload, { small: true });
});
