/**
 * File explorer backend. Walks the cloned repo and exposes a JSON-friendly
 * directory listing + a diff against the base branch.
 */
import { promises as fs } from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

export interface DirEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  size: number;
  modifiedAt: string;
}

const IGNORED = new Set([".git", "node_modules", "build", "DerivedData", ".DS_Store"]);

export async function listDir(workdir: string, rel: string): Promise<DirEntry[]> {
  const absolute = path.resolve(workdir, rel);
  if (!absolute.startsWith(workdir)) {
    throw new Error("Path escapes workdir.");
  }
  let dirents;
  try {
    dirents = await fs.readdir(absolute, { withFileTypes: true });
  } catch (err) {
    throw new Error(`Cannot read directory: ${(err as Error).message}`);
  }
  const out: DirEntry[] = [];
  for (const entry of dirents) {
    if (IGNORED.has(entry.name)) continue;
    const full = path.join(absolute, entry.name);
    let stat;
    try {
      stat = await fs.stat(full);
    } catch {
      continue;
    }
    out.push({
      name: entry.name,
      path: path.relative(workdir, full),
      isDirectory: entry.isDirectory(),
      size: stat.size,
      modifiedAt: stat.mtime.toISOString(),
    });
  }
  // Directories first, then alphabetical.
  out.sort((a, b) => {
    if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
  return out;
}

const MAX_READ = 256 * 1024; // 256 KB

export async function readFile(workdir: string, rel: string): Promise<{ content: string; truncated: boolean }> {
  const absolute = path.resolve(workdir, rel);
  if (!absolute.startsWith(workdir)) throw new Error("Path escapes workdir.");
  const stat = await fs.stat(absolute);
  if (stat.isDirectory()) throw new Error("Is a directory.");
  if (stat.size > MAX_READ) {
    const handle = await fs.open(absolute, "r");
    try {
      const buf = Buffer.alloc(MAX_READ);
      await handle.read(buf, 0, MAX_READ, 0);
      return { content: buf.toString("utf8"), truncated: true };
    } finally {
      await handle.close();
    }
  }
  const text = await fs.readFile(absolute, "utf8");
  return { content: text, truncated: false };
}

export async function diffAgainstBase(workdir: string): Promise<string> {
  try {
    const { stdout } = await execFileP("git", [
      "diff", "--stat", "HEAD~1", "HEAD"
    ], { cwd: workdir });
    return stdout;
  } catch {
    return "";
  }
}
