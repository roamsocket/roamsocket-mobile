/**
 * Live WebSocket session e2e (pair → open → create_session → user_message).
 *
 * Usage:
 *   # terminal A
 *   PORT=4329 APC_MOCK=1 APC_AUTO_TUNNEL=0 APC_HOST=0.0.0.0 npx tsx src/index.ts
 *   # terminal B (use the printed pairing code)
 *   APC_BASE=http://127.0.0.1:4329 APC_PAIR_CODE=123456 npx tsx scripts/ws-session-e2e.ts
 *
 * Also validates that a bad token closes with 4001 and that a 120ms post-open
 * settle (matching the iOS client) still allows create_session without
 * "Socket is not connected".
 */
import { WebSocket } from "ws";

const BASE = (process.env.APC_BASE ?? "http://127.0.0.1:4319").replace(/\/$/, "");
const CODE = process.env.APC_PAIR_CODE ?? "";

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function wsURL(token: string) {
  const u = new URL(BASE);
  u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
  u.pathname = "/session";
  u.search = `token=${encodeURIComponent(token)}`;
  return u.toString();
}

async function main() {
  if (!CODE) {
    console.error("Set APC_PAIR_CODE to the desktop pairing code.");
    process.exit(2);
  }

  const health = await (await fetch(`${BASE}/health`)).json() as { ok?: boolean };
  if (!health.ok) throw new Error("health not ok");
  console.log("PASS health");

  const pairRes = await fetch(`${BASE}/pair`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code: CODE, deviceName: "ws-session-e2e" }),
  });
  const pairBody = (await pairRes.json()) as { token?: string; error?: string };
  if (!pairRes.ok || !pairBody.token) {
    throw new Error(`pair failed: ${JSON.stringify(pairBody)}`);
  }
  console.log("PASS pair");

  // Bad token → 4001
  await new Promise<void>((resolve, reject) => {
    const ws = new WebSocket(wsURL("deadbeef"));
    const t = setTimeout(() => reject(new Error("bad-token timeout")), 5000);
    ws.on("close", (c) => {
      clearTimeout(t);
      if (c === 4001) {
        console.log("PASS bad-token close 4001");
        resolve();
      } else {
        reject(new Error(`expected 4001 got ${c}`));
      }
    });
    ws.on("error", () => {
      /* ignore — close carries the code */
    });
  });

  // Full happy path with 120ms settle (iOS client behavior)
  await new Promise<void>((resolve, reject) => {
    const ws = new WebSocket(wsURL(pairBody.token!));
    const t = setTimeout(() => {
      ws.terminate();
      reject(new Error("session timeout"));
    }, 25_000);

    ws.on("open", async () => {
      await sleep(120);
      if (ws.readyState !== WebSocket.OPEN) {
        clearTimeout(t);
        reject(new Error(`socket not open after settle (state=${ws.readyState})`));
        return;
      }
      console.log("PASS socket open after 120ms settle");
      const sessionId = `s_e2e_${Date.now().toString(36)}`;
      try {
        ws.send(
          JSON.stringify({
            type: "create_session",
            sessionId,
            repo: { fullName: "octocat/Hello-World", workBranch: "apc/e2e" },
            model: { provider: "mock", model: "mock", apiKey: "x", effort: "low" },
            permissionMode: "acceptEdits",
          }),
        );
        console.log("PASS create_session sent");
      } catch (e) {
        clearTimeout(t);
        reject(e);
      }
    });

    ws.on("message", (data) => {
      const msg = JSON.parse(String(data)) as {
        type: string;
        sessionId?: string;
        message?: string;
      };
      console.log("<<", msg.type, msg.message ?? "");
      if (msg.type === "session_created" && msg.sessionId) {
        try {
          ws.send(
            JSON.stringify({
              type: "user_message",
              sessionId: msg.sessionId,
              text: "hello from ws-session-e2e",
            }),
          );
          console.log("PASS user_message sent");
        } catch (e) {
          clearTimeout(t);
          reject(e);
        }
      }
      if (msg.type === "session_done") {
        clearTimeout(t);
        ws.close();
        resolve();
      }
      if (msg.type === "error" && (msg.message ?? "").includes("Unknown session")) {
        clearTimeout(t);
        reject(new Error(msg.message));
      }
    });

    ws.on("error", (err) => {
      clearTimeout(t);
      reject(err);
    });
  });

  console.log("ALL_PASS");
}

main().catch((err) => {
  console.error("FAIL", err);
  process.exit(1);
});
