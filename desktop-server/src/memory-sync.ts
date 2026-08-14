/**
 * User-memory sync on the desktop. Mirrors the iOS UserMemoryStore layout:
 * a single `memory.json` at the repo root, with the full list of entries.
 *
 * Conflict resolution: last-write-wins by `updatedAt`. Good enough for a
 * private single-user device pair. If you want CRDT later, swap this out.
 */
import { promises as fs } from "node:fs";
import path from "node:path";
import {
  commitAndPush,
  deleteFile,
  localDirFor,
  pullOrClone,
  writeFile,
  type RepoConfig,
} from "./git/ops.js";
import type { MemoryEntry } from "./protocol.js";

const MEMORY_FILE = "memory.json";

interface MemoryFile {
  entries: MemoryEntry[];
}

function readMemoryFile(repoUrl: string): Promise<MemoryEntry[]> {
  return (async () => {
    const target = path.join(localDirFor(repoUrl), MEMORY_FILE);
    try {
      const raw = await fs.readFile(target, "utf8");
      const parsed = JSON.parse(raw) as MemoryFile;
      if (!parsed || !Array.isArray(parsed.entries)) return [];
      return parsed.entries.filter(
        (e): e is MemoryEntry =>
          !!e &&
          typeof e.id === "string" &&
          typeof e.title === "string" &&
          (e.category === "you" || e.category === "topic" || e.category === "area"),
      );
    } catch {
      return [];
    }
  })();
}

async function writeMemoryFile(repoUrl: string, entries: MemoryEntry[]): Promise<string> {
  const json = JSON.stringify({ entries }, null, 2) + "\n";
  return await writeFile(repoUrl, MEMORY_FILE, json);
}

export async function syncMemoryRepo(
  config: RepoConfig,
  token?: string,
): Promise<MemoryEntry[]> {
  await pullOrClone(config, token);
  return await readMemoryFile(config.url);
}

export async function upsertMemoryEntry(
  entry: MemoryEntry,
  config: RepoConfig,
  token: string | undefined,
  author: { name: string; email: string },
): Promise<string> {
  await pullOrClone(config, token);
  const existing = await readMemoryFile(config.url);
  const next = mergeEntry(existing, entry);
  await writeMemoryFile(config.url, next);
  return await commitAndPush({
    config,
    token,
    message: `Update memory: ${entry.title}`,
    author,
  });
}

export async function removeMemoryEntry(
  id: string,
  config: RepoConfig,
  token: string | undefined,
  author: { name: string; email: string },
): Promise<string | null> {
  await pullOrClone(config, token);
  const existing = await readMemoryFile(config.url);
  const next = existing.filter((e) => e.id !== id);
  if (next.length === existing.length) return null;
  await writeMemoryFile(config.url, next);
  return await commitAndPush({
    config,
    token,
    message: `Remove memory: ${id}`,
    author,
  });
}

/** Last-write-wins on updatedAt; preserve untouched entries. */
function mergeEntry(existing: MemoryEntry[], incoming: MemoryEntry): MemoryEntry[] {
  const idx = existing.findIndex((e) => e.id === incoming.id);
  if (idx < 0) {
    return [incoming, ...existing];
  }
  if (incoming.updatedAt <= existing[idx]!.updatedAt) {
    return existing;
  }
  const out = existing.slice();
  out[idx] = incoming;
  return out;
}

// `deleteFile` is exported for callers that want to wipe the entire
// memory file; not used by the sync ops themselves.
export { deleteFile as removeMemoryFile };
