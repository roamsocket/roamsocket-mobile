/**
 * Port detection across macOS, Linux, and Windows.
 *
 * - Unix: `lsof -nP -iTCP -sTCP:LISTEN`
 * - Windows: PowerShell `Get-NetTCPConnection` (fallback: `netstat -ano`)
 *
 * Used by the iOS app / desktop UI to surface dev servers for tunneling.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

export interface ListeningPort {
  port: number;
  pid: number;
  command: string;
}

export async function listListeningPorts(): Promise<ListeningPort[]> {
  if (process.platform === "win32") {
    return listWindowsPorts();
  }
  return listUnixPorts();
}

async function listUnixPorts(): Promise<ListeningPort[]> {
  try {
    const { stdout } = await execFileP(
      "lsof",
      ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"],
      { maxBuffer: 4 * 1024 * 1024 },
    );
    return dedupe(parseLsof(stdout));
  } catch (err) {
    if ((err as { code?: string }).code === "ENOENT") {
      // Busybox / minimal environments: try ss
      return listViaSs().catch(() => []);
    }
    // lsof returns non-zero when nothing is listening.
    return [];
  }
}

async function listViaSs(): Promise<ListeningPort[]> {
  const { stdout } = await execFileP("ss", ["-ltnp"], { maxBuffer: 4 * 1024 * 1024 });
  const out: ListeningPort[] = [];
  for (const line of stdout.split("\n")) {
    // LISTEN 0 128 *:3000 *:* users:(("node",pid=123,fd=23))
    if (!line.includes("LISTEN")) continue;
    const portMatch = line.match(/:(\d+)\s/);
    const pidMatch = line.match(/pid=(\d+)/);
    const cmdMatch = line.match(/\(\("([^"]+)"/);
    if (!portMatch) continue;
    const port = Number(portMatch[1]);
    if (!Number.isFinite(port) || port <= 0) continue;
    out.push({
      port,
      pid: pidMatch ? Number(pidMatch[1]) : 0,
      command: cmdMatch?.[1] ?? "",
    });
  }
  return dedupe(out);
}

async function listWindowsPorts(): Promise<ListeningPort[]> {
  // Prefer Get-NetTCPConnection (Win8+ / Server 2012+).
  try {
    const ps = `
$ErrorActionPreference = 'SilentlyContinue'
Get-NetTCPConnection -State Listen |
  Select-Object -Property LocalPort, OwningProcess |
  ConvertTo-Csv -NoTypeInformation
`;
    const { stdout } = await execFileP(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", ps],
      { maxBuffer: 4 * 1024 * 1024, windowsHide: true },
    );
    const rows = parseCsvPorts(stdout);
    if (rows.length) {
      // Enrich with process names via Get-Process (batch).
      const pids = [...new Set(rows.map((r) => r.pid).filter((p) => p > 0))];
      const names = await windowsProcessNames(pids);
      return dedupe(
        rows.map((r) => ({
          ...r,
          command: names.get(r.pid) ?? r.command,
        })),
      );
    }
  } catch {
    /* fall through to netstat */
  }
  return listWindowsNetstat();
}

function parseCsvPorts(csv: string): ListeningPort[] {
  const lines = csv.split(/\r?\n/).filter(Boolean);
  if (lines.length < 2) return [];
  // "LocalPort","OwningProcess"
  const out: ListeningPort[] = [];
  for (const line of lines.slice(1)) {
    const m = line.match(/"?(\d+)"?\s*,\s*"?(\d+)"?/);
    if (!m) continue;
    const port = Number(m[1]);
    const pid = Number(m[2]);
    if (Number.isFinite(port) && port > 0) {
      out.push({ port, pid: Number.isFinite(pid) ? pid : 0, command: "" });
    }
  }
  return out;
}

async function windowsProcessNames(pids: number[]): Promise<Map<number, string>> {
  const map = new Map<number, string>();
  if (!pids.length) return map;
  try {
    const list = pids.join(",");
    const ps = `
$ErrorActionPreference = 'SilentlyContinue'
Get-Process -Id ${list} | Select-Object Id, ProcessName | ConvertTo-Csv -NoTypeInformation
`;
    const { stdout } = await execFileP(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", ps],
      { maxBuffer: 2 * 1024 * 1024, windowsHide: true },
    );
    for (const line of stdout.split(/\r?\n/).slice(1)) {
      const m = line.match(/"?(\d+)"?\s*,\s*"?([^"]*)"?/);
      if (m) map.set(Number(m[1]), m[2] || "");
    }
  } catch {
    /* ignore */
  }
  return map;
}

async function listWindowsNetstat(): Promise<ListeningPort[]> {
  try {
    const { stdout } = await execFileP("netstat", ["-ano", "-p", "tcp"], {
      maxBuffer: 4 * 1024 * 1024,
      windowsHide: true,
    });
    const out: ListeningPort[] = [];
    for (const line of stdout.split(/\r?\n/)) {
      // TCP    0.0.0.0:3000    0.0.0.0:0    LISTENING    1234
      const m = line.trim().match(/^TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)/i);
      if (!m) continue;
      const port = Number(m[1]);
      const pid = Number(m[2]);
      if (Number.isFinite(port) && port > 0) {
        out.push({ port, pid: Number.isFinite(pid) ? pid : 0, command: "" });
      }
    }
    return dedupe(out);
  } catch {
    return [];
  }
}

function parseLsof(output: string): ListeningPort[] {
  const lines = output.split("\n");
  const out: ListeningPort[] = [];
  let pid: number | null = null;
  let command: string | null = null;
  for (const line of lines) {
    if (!line) continue;
    const field = line[0];
    const value = line.slice(1);
    if (field === "p") {
      pid = Number(value);
    } else if (field === "c") {
      command = value;
    } else if (field === "n" && pid != null) {
      // "127.0.0.1:3000" or "*:3000" or "[::1]:3000"
      const m = value.match(/:(\d+)$/);
      if (m) {
        const port = Number(m[1]);
        if (Number.isFinite(port) && port > 0) {
          out.push({ port, pid, command: command ?? "" });
        }
      }
    }
  }
  return out;
}

function dedupe(ports: ListeningPort[]): ListeningPort[] {
  const seen = new Set<number>();
  return ports
    .filter((p) => {
      if (seen.has(p.port)) return false;
      seen.add(p.port);
      return true;
    })
    .sort((a, b) => a.port - b.port);
}
