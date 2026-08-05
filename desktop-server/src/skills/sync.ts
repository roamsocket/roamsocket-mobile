/**
 * Skills sync on the desktop. Mirrors the iOS SkillManager layout:
 *   <repo>/<skill-id>/SKILL.md
 *
 * Each `SKILL.md` has YAML frontmatter (`name`, `description`) followed by
 * a markdown body. We parse the file, expose the list to the iOS app over
 * the WebSocket, and accept upsert/delete commands.
 */
import { promises as fs } from "node:fs";
import path from "node:path";
import { commitAndPush, deleteFile, localDirFor, pullOrClone, writeFile, type RepoConfig } from "../git/ops.js";
import type { Skill } from "../protocol.js";

interface SkillFrontmatter {
  name?: string;
  description?: string;
  [k: string]: string | undefined;
}

function parseFrontmatter(text: string): { fm: SkillFrontmatter; body: string } {
  if (!text.startsWith("---")) return { fm: {}, body: text };
  const lines = text.split(/\r?\n/);
  if (lines.length < 2 || (lines[0]?.trim() !== "---")) return { fm: {}, body: text };
  let end = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i]?.trim() === "---") { end = i; break; }
  }
  if (end < 0) return { fm: {}, body: text };
  const fm: SkillFrontmatter = {};
  let currentKey: string | undefined;
  for (let i = 1; i < end; i++) {
    const line = lines[i] ?? "";
    if (line.startsWith("  ") || line.startsWith("\t")) {
      if (currentKey) {
        const prev = fm[currentKey] ?? "";
        fm[currentKey] = (prev + " " + line.trim()).trim();
      }
    } else {
      const colon = line.indexOf(":");
      if (colon > 0) {
        const key = line.slice(0, colon).trim();
        let value = line.slice(colon + 1).trim();
        if (value.startsWith(">")) value = value.slice(1).trim();
        if (value.startsWith('"') && value.endsWith('"')) value = value.slice(1, -1);
        if (key.length > 0) {
          fm[key] = value;
          currentKey = key;
        }
      }
    }
  }
  const body = lines.slice(end + 1).join("\n");
  return { fm, body };
}

function renderSkill(skill: Skill): string {
  const lines: string[] = ["---"];
  // Preserve keys other than name/description from the original frontmatter.
  for (const [key, val] of Object.entries(skill.frontmatter ?? {})) {
    if (key === "name" || key === "description") continue;
    if (typeof val === "string" && val.length > 0) {
      lines.push(`${key}: ${val}`);
    }
  }
  lines.push(`name: ${skill.name}`);
  lines.push(`description: ${skill.description}`);
  lines.push("---", "");
  lines.push(skill.content ?? "");
  return lines.join("\n");
}

export async function listSkills(repoUrl: string): Promise<Skill[]> {
  const dir = localDirFor(repoUrl);
  let entries: string[] = [];
  try {
    entries = await fs.readdir(dir);
  } catch {
    return [];
  }
  const out: Skill[] = [];
  for (const entry of entries) {
    const skillFile = path.join(dir, entry, "SKILL.md");
    try {
      const text = await fs.readFile(skillFile, "utf8");
      const { fm, body } = parseFrontmatter(text);
      out.push({
        id: entry,
        name: fm.name ?? entry,
        description: fm.description ?? "",
        content: body,
        category: "other" as Skill["category"],
        source: "custom" as Skill["source"],
        isEnabled: true,
        frontmatter: fm as Record<string, string>,
      });
    } catch {
      continue;
    }
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  return out;
}

export async function syncSkillsRepo(
  config: RepoConfig,
  token?: string,
): Promise<Skill[]> {
  await pullOrClone(config, token);
  return await listSkills(config.url);
}

export async function upsertSkill(
  skill: Skill,
  config: RepoConfig,
  token: string | undefined,
  author: { name: string; email: string },
): Promise<string> {
  await pullOrClone(config, token);
  const text = renderSkill(skill);
  await writeFile(config.url, `${skill.id}/SKILL.md`, text);
  return await commitAndPush({
    config,
    token,
    message: `Update skill: ${skill.name}`,
    author,
  });
}

export async function removeSkill(
  id: string,
  config: RepoConfig,
  token: string | undefined,
  author: { name: string; email: string },
): Promise<string | null> {
  await pullOrClone(config, token);
  await deleteFile(config.url, `${id}/SKILL.md`);
  return await commitAndPush({
    config,
    token,
    message: `Remove skill: ${id}`,
    author,
  });
}
