/**
 * One-time importer: reads skills and MCP servers from common local agent
 * directories on disk, then pushes them to the configured git repos as the
 * initial commit.
 *
 * Scans (first existing wins per layout):
 *   - `~/.anyprov/skills`, `~/.claude/skills`
 *   - `~/.anyprov/plugins/marketplaces`, `~/.claude/plugins/marketplaces`
 *
 * NOT bundled into the app — this is a user-triggered import action that
 * the desktop performs when the user asks it to. After the initial push,
 * both apps edit the repos directly via git, not via this importer.
 */
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import {
  commitAndPush,
  pullOrClone,
  writeFile,
  type RepoConfig,
} from "../git/ops.js";
import type { MCPServer, Skill } from "../protocol.js";

const HOME = os.homedir();
const SKILL_DIRS = [
  path.join(HOME, ".anyprov", "skills"),
  path.join(HOME, ".claude", "skills"),
];
const MARKETPLACE_DIRS = [
  path.join(HOME, ".anyprov", "plugins", "marketplaces"),
  path.join(HOME, ".claude", "plugins", "marketplaces"),
];

export async function discoverLocalSkills(): Promise<Skill[]> {
  const out: Skill[] = [];
  const seen = new Set<string>();
  for (const skillsDir of SKILL_DIRS) {
    let entries: string[] = [];
    try {
      entries = await fs.readdir(skillsDir);
    } catch {
      continue;
    }
    for (const id of entries) {
      if (seen.has(id)) continue;
      const skillFile = path.join(skillsDir, id, "SKILL.md");
      try {
        const text = await fs.readFile(skillFile, "utf8");
        const { name, description, body } = crudeParse(text);
        seen.add(id);
        out.push({
          id,
          name: name ?? id,
          description: description ?? "",
          content: body,
          category: "other" as Skill["category"],
          source: "custom" as Skill["source"],
          isEnabled: true,
          frontmatter: { name: name ?? id, description: description ?? "" } as Record<string, string>,
        });
      } catch {
        // Skip silently; the user can edit the file before pushing.
      }
    }
  }
  return out;
}

function crudeParse(text: string): { name?: string; description?: string; body: string } {
  if (!text.startsWith("---")) return { body: text };
  const lines = text.split(/\r?\n/);
  if (lines.length < 2 || (lines[0] ?? "").trim() !== "---") return { body: text };
  let end = -1;
  for (let i = 1; i < lines.length; i++) {
    if ((lines[i] ?? "").trim() === "---") { end = i; break; }
  }
  if (end < 0) return { body: text };
  const fm: Record<string, string> = {};
  for (let i = 1; i < end; i++) {
    const line = lines[i] ?? "";
    const colon = line.indexOf(":");
    if (colon > 0) {
      const key = line.slice(0, colon).trim();
      let value = line.slice(colon + 1).trim();
      if (value.startsWith(">")) value = value.slice(1).trim();
      fm[key] = value;
    }
  }
  return { name: fm.name, description: fm.description, body: lines.slice(end + 1).join("\n") };
}

export async function discoverLocalMCPServers(): Promise<MCPServer[]> {
  const out: MCPServer[] = [];
  const seen = new Set<string>();
  for (const marketplacesRoot of MARKETPLACE_DIRS) {
    let marketplaceDirs: string[] = [];
    try {
      marketplaceDirs = await fs.readdir(marketplacesRoot);
    } catch {
      continue;
    }
    for (const mp of marketplaceDirs) {
      const file = path.join(marketplacesRoot, mp, ".mcp.json");
      let raw: string;
      try {
        raw = await fs.readFile(file, "utf8");
      } catch {
        continue;
      }
      let data: { mcpServers?: Record<string, unknown> };
      try {
        data = JSON.parse(raw);
      } catch {
        continue;
      }
      const servers = Object.entries(data.mcpServers ?? {});
      for (const [name, spec] of servers) {
        const id = `${mp}-${name}`;
        if (seen.has(id)) continue;
        seen.add(id);
        const s = spec as Record<string, unknown>;
        out.push({
          id,
          name,
          description: typeof s.description === "string" ? s.description : "",
          command: typeof s.command === "string" ? s.command : "",
          args: Array.isArray(s.args) ? s.args as string[] : [],
          env: (typeof s.env === "object" && s.env) ? s.env as Record<string, string> : {},
          isEnabled: typeof s.isEnabled === "boolean" ? s.isEnabled : true,
        });
      }
    }
  }
  return out;
}

export async function importLocalSkillsToRepo(
  repo: RepoConfig,
  token: string | undefined,
  author: { name: string; email: string },
): Promise<{ imported: number; sha: string | null }> {
  const skills = await discoverLocalSkills();
  if (skills.length === 0) return { imported: 0, sha: null };
  await pullOrClone(repo, token);
  for (const skill of skills) {
    const yaml = [
      "---",
      `name: ${skill.name}`,
      `description: ${skill.description}`,
      "---",
      "",
      skill.content ?? "",
    ].join("\n");
    await writeFile(repo.url, `${skill.id}/SKILL.md`, yaml);
  }
  const sha = await commitAndPush({
    config: repo,
    token,
    message: `Import ${skills.length} skills from local skill directories`,
    author,
  });
  return { imported: skills.length, sha };
}

export async function importLocalMCPToRepo(
  repo: RepoConfig,
  token: string | undefined,
  author: { name: string; email: string },
): Promise<{ imported: number; sha: string | null }> {
  const servers = await discoverLocalMCPServers();
  if (servers.length === 0) return { imported: 0, sha: null };
  await pullOrClone(repo, token);
  for (const server of servers) {
    const file: McpFile = {
      mcpServers: {
        [server.name]: {
          type: server.command ? "stdio" : "http",
          command: server.command || undefined,
          args: server.args?.length ? server.args : undefined,
          env: Object.keys(server.env ?? {}).length ? server.env : undefined,
          description: server.description || undefined,
          isEnabled: server.isEnabled,
        },
      },
    };
    await writeFile(repo.url, `${server.id}/.mcp.json`, JSON.stringify(file, null, 2) + "\n");
  }
  const sha = await commitAndPush({
    config: repo,
    token,
    message: `Import ${servers.length} MCP servers from local marketplaces`,
    author,
  });
  return { imported: servers.length, sha };
}

interface McpServerSpec {
  type: string;
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  description?: string;
  isEnabled?: boolean;
}
interface McpFile {
  mcpServers: Record<string, McpServerSpec>;
}
