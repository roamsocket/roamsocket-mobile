/**
 * End-to-end smoke test with no network or API key. It:
 *   1. creates a local git repo to act as "origin",
 *   2. starts the server with the mock agent,
 *   3. pairs over HTTP, opens the WebSocket,
 *   4. creates a session (clones the local repo), sends a user message,
 *   5. asserts the mock agent wrote a file, produced a diff, and finished,
 *   6. creates a PR (pushes the work branch to the local origin).
 *
 * Run with: npm run smoke
 */
import { spawn, spawnSync } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { WebSocket } from "ws";

const PORT = 4571;
const BASE = `http://localhost:${PORT}`;

function git(cwd: string, ...args: string[]): void {
  const r = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr}`);
}

async function makeOriginRepo(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), "cmai-origin-"));
  git(dir, "init", "-b", "main");
  git(dir, "config", "user.email", "test@example.com");
  git(dir, "config", "user.name", "Test");
  await writeFile(path.join(dir, "README.md"), "# Test repo\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-m", "initial");
  // Allow pushes to this non-bare repo's non-checked-out branches.
  git(dir, "config", "receive.denyCurrentBranch", "ignore");
  return dir;
}

function waitForCode(child: ReturnType<typeof spawn>): Promise<string> {
  return new Promise((resolve, reject) => {
    let buf = "";
    const onData = (d: Buffer) => {
      buf += d.toString();
      const m = buf.match(/Pairing code: (\d{6})/);
      if (m) resolve(m[1]!);
    };
    child.stdout?.on("data", onData);
    child.stderr?.on("data", (d) => (buf += d.toString()));
    setTimeout(() => reject(new Error(`Server did not print pairing code.\n${buf}`)), 15000);
  });
}

async function pair(code: string): Promise<string> {
  const res = await fetch(`${BASE}/pair`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code, deviceName: "smoke-test" }),
  });
  if (!res.ok) throw new Error(`pair failed: ${res.status} ${await res.text()}`);
  const body = (await res.json()) as { token: string };
  return body.token;
}

function assert(cond: unknown, msg: string): void {
  if (!cond) throw new Error(`ASSERT FAILED: ${msg}`);
}

async function main(): Promise<void> {
  const origin = await makeOriginRepo();

  const server = spawn("npx", ["tsx", "src/index.ts"], {
    cwd: process.cwd(),
    env: { ...process.env, PORT: String(PORT), CMAI_MOCK: "1" },
  });

  try {
    const code = await waitForCode(server);
    const token = await pair(code);
    console.log("paired, token acquired");

    const ws = new WebSocket(`ws://localhost:${PORT}/session?token=${token}`);
    const seen: string[] = [];
    let diffForNotes = false;
    let prUrl = "";

    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error(`timeout; saw: ${seen.join(", ")}`)), 30000);

      ws.on("open", () => {
        ws.send(
          JSON.stringify({
            type: "create_session",
            sessionId: "smoke",
            repo: { fullName: origin, workBranch: "cmai/smoke-test" },
            model: { provider: "anthropic", model: "mock", apiKey: "none", effort: "high" },
            permissionMode: "acceptEdits",
          }),
        );
      });

      ws.on("message", (data) => {
        const msg = JSON.parse(data.toString());
        seen.push(msg.type);
        if (msg.type === "session_created") {
          ws.send(JSON.stringify({ type: "user_message", sessionId: "smoke", text: "add a notes file" }));
        } else if (msg.type === "diff" && msg.path === "NOTES.md") {
          diffForNotes = true;
        } else if (msg.type === "session_done") {
          ws.send(JSON.stringify({ type: "create_pr", sessionId: "smoke", title: "Add NOTES.md", body: "" }));
        } else if (msg.type === "pr_created") {
          prUrl = msg.url;
          clearTimeout(timeout);
          resolve();
        } else if (msg.type === "error") {
          clearTimeout(timeout);
          reject(new Error(`server error: ${msg.message} (saw: ${seen.join(", ")})`));
        }
      });
      ws.on("error", reject);
    });

    ws.close();

    assert(seen.includes("session_created"), "session_created received");
    assert(seen.includes("tool_call"), "tool_call received");
    assert(seen.includes("tool_result"), "tool_result received");
    assert(diffForNotes, "diff for NOTES.md received");
    assert(seen.includes("session_done"), "session_done received");
    assert(prUrl.length > 0, "pr_created url received");

    console.log("\nSMOKE TEST PASSED");
    console.log("events:", seen.join(" -> "));
    console.log("pr url:", prUrl);
  } finally {
    server.kill("SIGKILL");
  }
}

main().catch((err) => {
  console.error("\nSMOKE TEST FAILED:", err.message);
  process.exit(1);
});
