/**
 * Port detection via `lsof`. Lists every process listening on a TCP port
 * on the desktop machine. Used by the iOS app to surface dev servers the
 * agent has started.
 *
 * On macOS this is `lsof -nP -iTCP -sTCP:LISTEN`. On Linux the same
 * flags work; on Windows we'd need a different approach (not implemented).
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
  if (process.platform === "win32") return [];
  try {
    const { stdout } = await execFileP("lsof", [
      "-nP",
      "-iTCP",
      "-sTCP:LISTEN",
      "-F", "pcn", // fields: process id, command name, network file
    ], { maxBuffer: 4 * 1024 * 1024 });
    return parseLsof(stdout);
  } catch (err) {
    // lsof returns non-zero when there's nothing to report.
    if ((err as { code?: string }).code === "ENOENT") return [];
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
      // value looks like "127.0.0.1:3000" or "*:3000"
      const colon = value.lastIndexOf(":");
      if (colon > 0) {
        const port = Number(value.slice(colon + 1));
        if (Number.isFinite(port) && port > 0) {
          out.push({ port, pid, command: command ?? "" });
        }
      }
    }
  }
  // Dedupe by port.
  const seen = new Set<number>();
  return out.filter((p) => {
    if (seen.has(p.port)) return false;
    seen.add(p.port);
    return true;
  }).sort((a, b) => a.port - b.port);
}
