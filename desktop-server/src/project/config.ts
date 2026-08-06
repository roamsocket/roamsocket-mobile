/**
 * Per-project `.claude/` config. When a session is created, after cloning
 * the user's repo, the desktop reads these files (if present) and merges
 * them into the session:
 *   - `.claude/settings.local.json` (env vars, allowed tools, model prefs)
 *   - `.claude/mcp.json` (project-scoped MCP servers)
 *   - `.claude/CLAUDE.md` (project instructions injected as skill content)
 *
 * Mirrors the same lookup the Claude CLI performs at session start.
 */
import { promises as fs } from "node:fs";
import path from "node:path";

export interface ProjectClaude {
  env: Record<string, string>;
  mcpServers: Array<{
    name: string;
    type: string;
    command?: string;
    args?: string[];
    env?: Record<string, string>;
    url?: string;
  }>;
  claudeMd: string | null;
  skills: Array<{ name: string; content: string }>;
}

const EMPTY: ProjectClaude = { env: {}, mcpServers: [], claudeMd: null, skills: [] };

/** Read every `.claude/` config from the cloned repo and return a merged view. */
export async function readProjectClaude(workdir: string): Promise<ProjectClaude> {
  const root = path.join(workdir, ".claude");
  let exists = false;
  try {
    const stat = await fs.stat(root);
    exists = stat.isDirectory();
  } catch {
    return EMPTY;
  }
  if (!exists) return EMPTY;

  const env = await readSettingsJson(path.join(root, "settings.local.json"));
  const mcp = await readMcpJson(path.join(root, "mcp.json"));
  const claudeMd = await readMaybeFile(path.join(root, "CLAUDE.md"));
  const skills = await readSkillsDir(path.join(root, "skills"));

  return { env, mcpServers: mcp, claudeMd, skills };
}

async function readMaybeFile(p: string): Promise<string | null> {
  try {
    return await fs.readFile(p, "utf8");
  } catch {
    return null;
  }
}

async function readSettingsJson(p: string): Promise<Record<string, string>> {
  try {
    const text = await fs.readFile(p, "utf8");
    const data = JSON.parse(text);
    if (data && typeof data === "object" && data.env && typeof data.env === "object") {
      const out: Record<string, string> = {};
      for (const [k, v] of Object.entries(data.env as Record<string, unknown>)) {
        if (typeof v === "string") out[k] = v;
      }
      return out;
    }
  } catch {
    /* fall through */
  }
  return {};
}

interface McpFile {
  mcpServers?: Record<string, McpSpec>;
}
interface McpSpec {
  type?: string;
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  url?: string;
}

async function readMcpJson(p: string): Promise<ProjectClaude["mcpServers"]> {
  try {
    const text = await fs.readFile(p, "utf8");
    const data = JSON.parse(text) as McpFile;
    const entries = Object.entries(data.mcpServers ?? {});
    return entries.map(([name, spec]) => ({
      name,
      type: spec.type ?? "stdio",
      command: spec.command,
      args: spec.args,
      env: spec.env,
      url: spec.url,
    }));
  } catch {
    return [];
  }
}

async function readSkillsDir(p: string): Promise<ProjectClaude["skills"]> {
  let entries: string[] = [];
  try {
    entries = await fs.readdir(p);
  } catch {
    return [];
  }
  const out: ProjectClaude["skills"] = [];
  for (const id of entries) {
    const skillFile = path.join(p, id, "SKILL.md");
    try {
      const text = await fs.readFile(skillFile, "utf8");
      // Strip the YAML frontmatter for the content we inject — the agent
      // sees just the markdown body. We keep the name from the directory.
      const body = text.replace(/^---\n[\s\S]*?\n---\n*/, "");
      out.push({ name: id, content: body });
    } catch {
      continue;
    }
  }
  return out;
}
