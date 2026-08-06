/**
 * File explorer backend. Walks the cloned repo and exposes a JSON-friendly
 * directory listing, working-tree git status, and unified diffs.
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
  /** Git status letter when the path is dirty: M, A, D, ?, R, etc. */
  changeStatus?: string;
}

export interface FileChange {
  path: string;
  status: string;
}

const IGNORED = new Set([".git", "node_modules", "build", "DerivedData", ".DS_Store"]);

export async function listDir(workdir: string, rel: string): Promise<DirEntry[]> {
  const absolute = path.resolve(workdir, rel || ".");
  if (!absolute.startsWith(path.resolve(workdir))) {
    throw new Error("Path escapes workdir.");
  }
  let dirents;
  try {
    dirents = await fs.readdir(absolute, { withFileTypes: true });
  } catch (err) {
    throw new Error(`Cannot read directory: ${(err as Error).message}`);
  }

  const statusMap = await gitStatusMap(workdir);
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
    const relPath = path.relative(workdir, full);
    const changeStatus =
      statusMap.get(relPath) ??
      // Directories inherit a status if any nested path is dirty.
      (entry.isDirectory()
        ? [...statusMap.keys()].some((p) => p === relPath || p.startsWith(relPath + path.sep) || p.startsWith(relPath + "/"))
          ? "M"
          : undefined
        : undefined);
    out.push({
      name: entry.name,
      path: relPath,
      isDirectory: entry.isDirectory(),
      size: stat.size,
      modifiedAt: stat.mtime.toISOString(),
      changeStatus,
    });
  }
  out.sort((a, b) => {
    if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
  return out;
}

const MAX_READ = 256 * 1024; // 256 KB

export async function readFile(
  workdir: string,
  rel: string,
): Promise<{ content: string; truncated: boolean; diff?: string }> {
  const absolute = path.resolve(workdir, rel);
  if (!absolute.startsWith(path.resolve(workdir))) throw new Error("Path escapes workdir.");
  const stat = await fs.stat(absolute);
  if (stat.isDirectory()) throw new Error("Is a directory.");
  let content: string;
  let truncated = false;
  if (stat.size > MAX_READ) {
    const handle = await fs.open(absolute, "r");
    try {
      const buf = Buffer.alloc(MAX_READ);
      await handle.read(buf, 0, MAX_READ, 0);
      content = buf.toString("utf8");
      truncated = true;
    } finally {
      await handle.close();
    }
  } else {
    content = await fs.readFile(absolute, "utf8");
  }
  const diff = await fileDiff(workdir, rel);
  return { content, truncated, diff: diff || undefined };
}

/**
 * Working-tree status map: relative path → short status (M/A/D/?/…).
 * Covers staged, unstaged, and untracked files.
 */
export async function gitStatusMap(workdir: string): Promise<Map<string, string>> {
  const map = new Map<string, string>();
  try {
    const { stdout } = await execFileP("git", ["status", "--porcelain", "-uall"], {
      cwd: workdir,
      maxBuffer: 8 * 1024 * 1024,
    });
    for (const line of stdout.split("\n")) {
      if (line.length < 4) continue;
      const xy = line.slice(0, 2);
      let filePath = line.slice(3);
      // Renames: "R  old -> new"
      if (filePath.includes(" -> ")) {
        filePath = filePath.split(" -> ").pop()!.trim();
      }
      filePath = filePath.replace(/^"|"$/g, "");
      // Prefer a meaningful letter: untracked, then index, then worktree.
      let letter = "?";
      if (xy === "??") letter = "?";
      else if (xy[0] !== " " && xy[0] !== "?") letter = xy[0]!;
      else if (xy[1] !== " " && xy[1] !== "?") letter = xy[1]!;
      map.set(filePath, letter);
    }
  } catch {
    /* not a git repo or git missing */
  }
  return map;
}

export async function listChanges(workdir: string): Promise<FileChange[]> {
  const map = await gitStatusMap(workdir);
  return [...map.entries()]
    .map(([p, status]) => ({ path: p, status }))
    .sort((a, b) => a.path.localeCompare(b.path));
}

/**
 * Human-readable summary + unified diff for the whole working tree
 * (unstaged + untracked intent). Used on the Diffs tab.
 */
export async function diffAgainstBase(workdir: string): Promise<string> {
  const parts: string[] = [];
  try {
    // Stage intent for untracked so they show in diff.
    await execFileP("git", ["add", "-AN"], { cwd: workdir }).catch(() => undefined);
    const { stdout: stat } = await execFileP(
      "git",
      ["diff", "--stat", "HEAD"],
      { cwd: workdir, maxBuffer: 4 * 1024 * 1024 },
    ).catch(async () => {
      // Empty repo / no commits yet.
      return execFileP("git", ["diff", "--stat"], { cwd: workdir, maxBuffer: 4 * 1024 * 1024 });
    });
    if (stat.trim()) parts.push(stat.trim());

    const { stdout: patch } = await execFileP(
      "git",
      ["diff", "HEAD"],
      { cwd: workdir, maxBuffer: 8 * 1024 * 1024 },
    ).catch(async () => execFileP("git", ["diff"], { cwd: workdir, maxBuffer: 8 * 1024 * 1024 }));
    if (patch.trim()) {
      // Cap enormous patches for the wire.
      parts.push(patch.length > 200_000 ? patch.slice(0, 200_000) + "\n… (truncated)" : patch);
    } else if (!stat.trim()) {
      // Untracked-only: show names from status.
      const changes = await listChanges(workdir);
      if (changes.length) {
        parts.push(changes.map((c) => `${c.status}\t${c.path}`).join("\n"));
      }
    }
  } catch {
    return "";
  }
  return parts.join("\n\n");
}

/** Unified diff for a single path vs HEAD (includes new files). */
export async function fileDiff(workdir: string, rel: string): Promise<string> {
  try {
    await execFileP("git", ["add", "-AN", "--", rel], { cwd: workdir }).catch(() => undefined);
    const { stdout } = await execFileP(
      "git",
      ["diff", "HEAD", "--", rel],
      { cwd: workdir, maxBuffer: 4 * 1024 * 1024 },
    ).catch(async () =>
      execFileP("git", ["diff", "--", rel], { cwd: workdir, maxBuffer: 4 * 1024 * 1024 }),
    );
    if (stdout.trim()) return stdout;
    // Brand-new untracked file: fabricate a simple "added" view.
    const status = (await gitStatusMap(workdir)).get(rel);
    if (status === "?" || status === "A") {
      const absolute = path.resolve(workdir, rel);
      if (!absolute.startsWith(path.resolve(workdir))) return "";
      try {
        const text = await fs.readFile(absolute, "utf8");
        const lines = text.split("\n");
        const body = lines.map((l) => `+${l}`).join("\n");
        return `--- /dev/null\n+++ b/${rel}\n@@ -0,0 +1,${lines.length} @@\n${body}`;
      } catch {
        return "";
      }
    }
    return "";
  } catch {
    return "";
  }
}
