/**
 * Launch Electron twice with APC_DOM_DUMP=1 and assert sidebar + chat shell
 * appear in the real renderer DOM after bootstrap.
 *
 * Usage: npx tsx scripts/electron-dom-check.ts
 */
import { spawn } from "node:child_process";
import { createWriteStream, appendFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const scratch =
  process.env.APC_SCRATCH ||
  path.join(root, ".vite"); // fallback; harness sets APC_SCRATCH

interface DomSnapshot {
  ok: boolean;
  reason?: string;
  href?: string;
  title?: string;
  bodyLen?: number;
  nav: Array<{ route: string | null; text: string; active: boolean }>;
  hasVisionNav: boolean;
  greeting: string | null;
  emptyHome: boolean;
  composer: boolean;
  views: Array<{ id: string; hidden: boolean }>;
  topbar: string | null;
  appPresent: boolean;
  sidebarPresent: boolean;
}

function assertSnapshot(s: DomSnapshot, label: string): void {
  if (!s.ok) throw new Error(`${label}: snapshot not ok`);
  if (!s.appPresent) throw new Error(`${label}: #app missing`);
  if (!s.sidebarPresent) throw new Error(`${label}: #sidebar missing`);
  if (s.hasVisionNav) throw new Error(`${label}: Vision must not be in primary nav`);

  const routes = s.nav.map((n) => n.route).filter(Boolean) as string[];
  for (const need of ["chats", "projects", "artifacts", "code"]) {
    if (!routes.includes(need)) {
      throw new Error(`${label}: missing nav route ${need}; got ${routes.join(",")}`);
    }
  }
  // Settings is footer cog button, not nav-item — require settings view exists
  const settingsView = s.views.find((v) => v.id === "settings");
  if (!settingsView) throw new Error(`${label}: settings view missing`);

  const chatsVisible = s.views.find((v) => v.id === "chats");
  if (!chatsVisible || chatsVisible.hidden) {
    throw new Error(`${label}: chats view should be visible on launch`);
  }
  if (!s.emptyHome && !s.greeting) {
    // Empty home may be empty if history restored a chat; still require composer
  }
  if (!s.composer) throw new Error(`${label}: chat composer (#chat-input) missing`);
  // Prefer empty greeting when no history — if present, must be non-empty string
  if (s.emptyHome && (!s.greeting || s.greeting.length < 3)) {
    throw new Error(`${label}: empty home missing greeting text`);
  }
  console.log(`${label}: OK nav=${routes.join(",")} greeting=${JSON.stringify(s.greeting)} empty=${s.emptyHome}`);
}

function runOnce(logPath: string, attempt: number): Promise<DomSnapshot> {
  return new Promise((resolve, reject) => {
    const out = createWriteStream(logPath, { flags: "a" });
    out.write(`\n===== DOM CHECK ATTEMPT ${attempt} =====\n`);

    // Prefer project electron binary
    const electronBin = path.join(root, "node_modules", "electron", "cli.js");
    const child = spawn(process.execPath, [electronBin, "."], {
      cwd: root,
      env: {
        ...process.env,
        APC_DOM_DUMP: "1",
        APC_DOM_DUMP_QUIT: "1",
        ELECTRON_ENABLE_LOGGING: "1",
        // Avoid pairing popup blocking headless-ish runs
        // (prefs may still show it; dump still runs)
      },
      stdio: ["ignore", "pipe", "pipe"],
    });

    let buf = "";
    let settled = false;
    const onData = (chunk: Buffer) => {
      const t = chunk.toString();
      buf += t;
      out.write(t);
      const m = buf.match(/\[apc\] DOM_SNAPSHOT ({.*})/);
      if (m && !settled) {
        settled = true;
        try {
          const snap = JSON.parse(m[1]!) as DomSnapshot;
          child.kill("SIGTERM");
          setTimeout(() => child.kill("SIGKILL"), 1500);
          resolve(snap);
        } catch (err) {
          reject(err);
        }
      }
    };
    child.stdout?.on("data", onData);
    child.stderr?.on("data", onData);

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill("SIGKILL");
      reject(new Error(`timeout waiting for DOM_SNAPSHOT (attempt ${attempt})\n${buf.slice(-2000)}`));
    }, 45_000);

    child.on("exit", () => {
      clearTimeout(timer);
      out.end();
      if (!settled) {
        settled = true;
        reject(new Error(`electron exited without DOM_SNAPSHOT (attempt ${attempt})\n${buf.slice(-2000)}`));
      }
    });
  });
}

/**
 * Prefer `electron-forge start` so MAIN_WINDOW_VITE_* defines and the
 * bundled main match production-dev. Spawning bare `electron .` against a
 * hand-rolled vite main build can break Node builtins (util.inherits).
 */
function runForgeOnce(logPath: string, attempt: number): Promise<DomSnapshot> {
  return new Promise((resolve, reject) => {
    appendFileSync(logPath, `\n===== DOM CHECK ATTEMPT ${attempt} (forge) =====\n`);
    const child = spawn("npm", ["run", "electron:dev"], {
      cwd: root,
      env: {
        ...process.env,
        APC_DOM_DUMP: "1",
        APC_DOM_DUMP_QUIT: "1",
        ELECTRON_ENABLE_LOGGING: "1",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let buf = "";
    let settled = false;
    const onData = (chunk: Buffer) => {
      const t = chunk.toString();
      buf += t;
      appendFileSync(logPath, t);
      const m = buf.match(/\[apc\] DOM_SNAPSHOT ({.*})/);
      if (m && !settled) {
        settled = true;
        try {
          const snap = JSON.parse(m[1]!) as DomSnapshot;
          child.kill("SIGTERM");
          setTimeout(() => child.kill("SIGKILL"), 2000);
          resolve(snap);
        } catch (err) {
          reject(err);
        }
      }
    };
    child.stdout?.on("data", onData);
    child.stderr?.on("data", onData);
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill("SIGKILL");
      reject(new Error(`timeout forge DOM_SNAPSHOT attempt ${attempt}\n${buf.slice(-2500)}`));
    }, 90_000);
    child.on("exit", () => {
      clearTimeout(timer);
      if (!settled) {
        settled = true;
        reject(new Error(`forge exited without DOM_SNAPSHOT attempt ${attempt}`));
      }
    });
  });
}

async function main() {
  const outDir = process.env.APC_SCRATCH || process.env.SCRATCH || scratch;
  const logPath = path.join(outDir, "electron-launch.log");
  writeFileSync(logPath, "electron DOM check\n");

  const snaps: DomSnapshot[] = [];
  for (let i = 1; i <= 2; i++) {
    if (i > 1) await new Promise((r) => setTimeout(r, 2500));
    const snap = await runForgeOnce(logPath, i);
    assertSnapshot(snap, `launch${i}`);
    snaps.push(snap);
    appendFileSync(
      logPath,
      `\nDOM_ASSERT launch${i} ok routes=${snap.nav.map((n) => n.route).join(",")}\n`,
    );
  }

  const routesPath = path.join(outDir, "routes.txt");
  writeFileSync(
    routesPath,
    [
      "sidebar:",
      ...snaps[0]!.nav.map((n) => `  ${n.route}: ${n.text}`),
      `settings view: present`,
      `vision: ${snaps[0]!.hasVisionNav ? "PRESENT (FAIL)" : "absent"}`,
      `greeting: ${snaps[0]!.greeting ?? "(chat resumed, no empty home)"}`,
      `composer: ${snaps[0]!.composer}`,
      `emptyHome: ${snaps[0]!.emptyHome}`,
      `href: ${snaps[0]!.href ?? ""}`,
    ].join("\n") + "\n",
  );

  console.log("electron DOM check passed (2 launches)");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
