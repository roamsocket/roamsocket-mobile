/**
 * Detect and kill leftover RoamSocket / desktop-server processes that
 * would block a clean Electron launch (usually something still holding the
 * HTTP port, or a headless `tsx watch` / `npm start` still running).
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { listListeningPorts } from "../workspace/ports.js";

const execFileP = promisify(execFile);

export interface ConflictingProcess {
  pid: number;
  command: string;
  /** Why we consider it a conflict (port holder, APC server, etc.). */
  reason: string;
}

/** Process names / command fragments that typically supervise our server. */
const SUPERVISOR_RE =
  /\b(tsx|npm|npx|yarn|pnpm|node|electron|electron-forge)\b/i;

/**
 * Command lines that look like our headless companion server or a packaged
 * main binary — not every process whose cwd happens to sit under the repo.
 */
/**
 * Match current RoamSocket process names plus LEGACY CLI/app names so
 * instance cleanup still finds older installs during transition.
 */
const APC_SERVER_RE =
  /(?:roamsocket-server|roamsocket-server|anyprov-code-server|code-mobile-ai-server|(?:^|[\\/\s])tsx(?:\s+watch)?\s+.*(?:src[\\/])?index\.ts|node\s+.*desktop-server[\\/].*dist[\\/](?:src[\\/])?index\.js|desktop-server[\\/](?:src[\\/]index\.ts|dist[\\/](?:src[\\/])?index\.js)|RoamSocket\.app[\\/]Contents[\\/]MacOS[\\/](?:roamsocket|roamsocket|anyprov-code)|Code Mobile AI\.app[\\/]Contents[\\/]MacOS[\\/]code-mobile-ai|(?:^|[\\/\s])(?:roamsocket|roamsocket|anyprov-code|code-mobile-ai)(?:\.exe)?(?:\s|$))/i;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isOurPid(pid: number): boolean {
  return pid === process.pid || pid === process.ppid || pid <= 0;
}

async function processCommand(pid: number): Promise<string> {
  if (process.platform === "win32") {
    try {
      const { stdout } = await execFileP(
        "powershell.exe",
        [
          "-NoProfile",
          "-NonInteractive",
          "-Command",
          `(Get-CimInstance Win32_Process -Filter "ProcessId=${pid}").CommandLine`,
        ],
        { maxBuffer: 256 * 1024, windowsHide: true },
      );
      return stdout.trim();
    } catch {
      return "";
    }
  }
  try {
    const { stdout } = await execFileP("ps", ["-p", String(pid), "-o", "command="], {
      maxBuffer: 256 * 1024,
    });
    return stdout.trim();
  } catch {
    return "";
  }
}

async function processParentPid(pid: number): Promise<number | null> {
  if (process.platform === "win32") {
    try {
      const { stdout } = await execFileP(
        "powershell.exe",
        [
          "-NoProfile",
          "-NonInteractive",
          "-Command",
          `(Get-CimInstance Win32_Process -Filter "ProcessId=${pid}").ParentProcessId`,
        ],
        { maxBuffer: 64 * 1024, windowsHide: true },
      );
      const n = Number(stdout.trim());
      return Number.isFinite(n) && n > 0 ? n : null;
    } catch {
      return null;
    }
  }
  try {
    const { stdout } = await execFileP("ps", ["-p", String(pid), "-o", "ppid="], {
      maxBuffer: 64 * 1024,
    });
    const n = Number(stdout.trim());
    return Number.isFinite(n) && n > 0 ? n : null;
  } catch {
    return null;
  }
}

/**
 * Walk up from a port-holder to the process we should actually kill.
 * `tsx watch` restarts children, so killing only the listener is useless —
 * kill the supervisor when it looks like one of ours.
 */
async function rootKillTarget(pid: number): Promise<ConflictingProcess> {
  let current = pid;
  let command = (await processCommand(current)) || `(pid ${current})`;
  const reason = `holding port`;

  for (let i = 0; i < 4; i++) {
    const ppid = await processParentPid(current);
    if (ppid == null || isOurPid(ppid) || ppid === 1) break;
    const parentCmd = await processCommand(ppid);
    if (!parentCmd) break;
    // Prefer killing tsx/npm/watch supervisors over the leaf node.
    const parentLooksLikeSupervisor =
      SUPERVISOR_RE.test(parentCmd) &&
      (APC_SERVER_RE.test(parentCmd) ||
        /\b(tsx|npm|npx|yarn|pnpm)\b/i.test(parentCmd));
    if (!parentLooksLikeSupervisor) break;
    current = ppid;
    command = parentCmd;
  }

  return { pid: current, command: truncateCmd(command), reason };
}

function truncateCmd(cmd: string, max = 120): string {
  const oneLine = cmd.replace(/\s+/g, " ").trim();
  return oneLine.length > max ? `${oneLine.slice(0, max - 1)}…` : oneLine;
}

async function listApcServerProcesses(): Promise<ConflictingProcess[]> {
  const out: ConflictingProcess[] = [];
  if (process.platform === "win32") {
    try {
      const { stdout } = await execFileP(
        "powershell.exe",
        [
          "-NoProfile",
          "-NonInteractive",
          "-Command",
          // LEGACY name fragments included so older installs are still cleaned up.
          `Get-CimInstance Win32_Process | Where-Object {
            $_.CommandLine -match 'roamsocket|roamsocket|anyprov-code|code-mobile-ai|desktop-server.*(index\\.(ts|js)|RoamSocket|Code Mobile AI)'
          } | Select-Object ProcessId, CommandLine | ConvertTo-Csv -NoTypeInformation`,
        ],
        { maxBuffer: 4 * 1024 * 1024, windowsHide: true },
      );
      for (const line of stdout.split(/\r?\n/).slice(1)) {
        const m = line.match(/"?(\d+)"?\s*,\s*"?(.*)"?\s*$/);
        if (!m) continue;
        const pid = Number(m[1]);
        if (!Number.isFinite(pid) || isOurPid(pid)) continue;
        const command = (m[2] ?? "").replace(/""/g, '"').replace(/^"|"$/g, "");
        if (!APC_SERVER_RE.test(command) && !/desktop-server/i.test(command)) continue;
        // Skip Electron helper processes of *this* app tree.
        if (/Helper/i.test(command) && command.includes(String(process.pid))) continue;
        out.push({
          pid,
          command: truncateCmd(command),
          reason: "RoamSocket server process",
        });
      }
    } catch {
      /* ignore */
    }
    return out;
  }

  try {
    const { stdout } = await execFileP("ps", ["-ax", "-o", "pid=,command="], {
      maxBuffer: 8 * 1024 * 1024,
    });
    for (const line of stdout.split("\n")) {
      const m = line.trim().match(/^(\d+)\s+(.*)$/);
      if (!m) continue;
      const pid = Number(m[1]);
      const command = m[2] ?? "";
      if (!Number.isFinite(pid) || isOurPid(pid)) continue;
      if (!APC_SERVER_RE.test(command)) continue;
      // Don't target Electron Helper processes — only mains / node servers.
      if (/Helper \(|Helper\.app|GPU Helper|Renderer Helper|Plugin Helper/i.test(command)) {
        continue;
      }
      out.push({
        pid,
        command: truncateCmd(command),
        reason: "RoamSocket server process",
      });
    }
  } catch {
    /* ignore */
  }
  return out;
}

/**
 * Find processes that would prevent this launch from binding `port`.
 * Includes the port holder (and its tsx/npm supervisor) plus other APC
 * headless/server processes.
 */
export async function findConflictingProcesses(port: number): Promise<ConflictingProcess[]> {
  const byPid = new Map<number, ConflictingProcess>();

  try {
    process.stderr.write(`[apc-debug] findConflictingProcesses: calling listListeningPorts port=${port}\n`);
    const ports = await listListeningPorts();
    process.stderr.write(`[apc-debug] findConflictingProcesses: listListeningPorts returned ${ports.length} ports\n`);
    for (const p of ports) {
      if (p.port !== port || isOurPid(p.pid)) continue;
      const target = await rootKillTarget(p.pid);
      byPid.set(target.pid, {
        ...target,
        reason: `listening on port ${port}`,
      });
    }
  } catch (err) {
    process.stderr.write(`[apc-debug] findConflictingProcesses: port scan failed: ${(err as Error).message}\n`);
    /* port scan failed — still try process list */
  }

  try {
    process.stderr.write(`[apc-debug] findConflictingProcesses: calling listApcServerProcesses\n`);
    const apcProcs = await listApcServerProcesses();
    process.stderr.write(`[apc-debug] findConflictingProcesses: listApcServerProcesses returned ${apcProcs.length} procs\n`);
    for (const proc of apcProcs) {
      if (isOurPid(proc.pid)) continue;
      // Avoid killing *this* Electron main if the command line matches the app name.
      // process.pid already excluded; also skip if command is clearly our own forge/dev parent chain.
      if (!byPid.has(proc.pid)) byPid.set(proc.pid, proc);
    }
  } catch (err) {
    process.stderr.write(`[apc-debug] findConflictingProcesses: listApcServerProcesses failed: ${(err as Error).message}\n`);
  }

  return [...byPid.values()].sort((a, b) => a.pid - b.pid);
}

/** Immediate child PIDs of `pid` (Unix). */
async function childPids(pid: number): Promise<number[]> {
  if (process.platform === "win32") return [];
  try {
    const { stdout } = await execFileP("pgrep", ["-P", String(pid)], {
      maxBuffer: 256 * 1024,
    });
    return stdout
      .split(/\s+/)
      .map((s) => Number(s))
      .filter((n) => Number.isFinite(n) && n > 0 && !isOurPid(n));
  } catch {
    return [];
  }
}

/**
 * Collect `pid` and all descendants (depth-first). Used so killing
 * `npm run dev` also stops the nested `tsx watch` / node listener.
 */
async function collectTree(pid: number, into: Set<number>): Promise<void> {
  if (isOurPid(pid) || into.has(pid)) return;
  into.add(pid);
  for (const child of await childPids(pid)) {
    await collectTree(child, into);
  }
}

async function signalPid(pid: number, signal: NodeJS.Signals): Promise<void> {
  try {
    process.kill(pid, signal);
  } catch {
    /* already gone */
  }
}

async function killOne(pid: number): Promise<void> {
  if (isOurPid(pid)) return;

  if (process.platform === "win32") {
    try {
      await execFileP("taskkill", ["/PID", String(pid), "/T", "/F"], {
        windowsHide: true,
      });
    } catch {
      try {
        process.kill(pid);
      } catch {
        /* already gone */
      }
    }
    return;
  }

  const tree = new Set<number>();
  await collectTree(pid, tree);
  // Children first, then the root (stable reverse insertion is fine).
  const ordered = [...tree].reverse();
  for (const p of ordered) await signalPid(p, "SIGTERM");
  await sleep(400);
  for (const p of ordered) {
    try {
      process.kill(p, 0);
      await signalPid(p, "SIGKILL");
    } catch {
      /* exited */
    }
  }
}

/** Force-kill the given PIDs (full process trees on every platform). */
export async function killProcesses(pids: number[]): Promise<void> {
  const unique = [...new Set(pids)].filter((p) => !isOurPid(p));
  // Sequential so parent/child overlap from the conflict list doesn't race.
  for (const pid of unique) {
    await killOne(pid);
  }
  // Give the OS a moment to release sockets (especially TIME_WAIT / macOS).
  await sleep(350);
}

/** True when something still appears to hold `port` (excluding us). */
export async function isPortHeld(port: number): Promise<boolean> {
  try {
    const ports = await listListeningPorts();
    return ports.some((p) => p.port === port && !isOurPid(p.pid));
  } catch {
    return false;
  }
}

/** Human-readable detail block for a confirmation dialog. */
export function formatConflictDetail(conflicts: ConflictingProcess[], port: number): string {
  const lines = conflicts.map(
    (c) => `• PID ${c.pid} — ${c.reason}\n  ${c.command || "(unknown command)"}`,
  );
  return (
    `Another process is using port ${port} or looks like a leftover RoamSocket server.\n\n` +
    `${lines.join("\n\n")}\n\n` +
    `Quit those processes so this launch can start cleanly?`
  );
}
