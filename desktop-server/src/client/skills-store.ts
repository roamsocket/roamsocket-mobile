/**
 * Local skills catalog + user overrides (edit / uninstall / share).
 * Built-ins ship with Claude-like stubs; edits persist in localStorage.
 */
import type { StorageLike } from "./history-store.js";

const KEY = "apc.skills.v1";

export interface SkillRecord {
  id: string;
  name: string;
  description: string;
  /** Full skill markdown / instructions */
  instructions: string;
  author: string;
  /** ISO date or display string */
  lastUpdated: string;
  /** e.g. "Slash command + auto" */
  trigger: string;
  share: boolean;
  /** Built-in vs user-added */
  builtin: boolean;
  /** Soft-deleted builtin */
  uninstalled?: boolean;
}

/** Default built-in skills (Claude-like). */
export const BUILTIN_SKILLS: SkillRecord[] = [
  {
    id: "apa-formatting",
    name: "apa-formatting",
    description: "APA citations and paper structure",
    instructions: `# APA Formatting

Help the user write papers following APA 7th edition: title page, running head, in-text citations, and reference lists.

## Invocation
- "format this in APA"
- "APA citations for …"
`,
    author: "You",
    lastUpdated: "2026-06-01",
    trigger: "Slash command + auto",
    share: false,
    builtin: true,
  },
  {
    id: "canvas-design",
    name: "canvas-design",
    description: "Canvas / visual layout guidance",
    instructions: `# Canvas Design

Guide layout, hierarchy, and visual composition for slides, posters, and canvas tools.

## Invocation
- "design a canvas for …"
- "improve this layout"
`,
    author: "You",
    lastUpdated: "2026-05-12",
    trigger: "Slash command + auto",
    share: false,
    builtin: true,
  },
  {
    id: "doc-coauthoring",
    name: "doc-coauthoring",
    description: "Collaborative document drafting",
    instructions: `# Doc Coauthoring

Draft and revise long-form docs with clear sections, comments, and change proposals.

## Invocation
- "coauthor this draft"
- "revise section 2"
`,
    author: "You",
    lastUpdated: "2026-04-20",
    trigger: "Slash command + auto",
    share: false,
    builtin: true,
  },
  {
    id: "frontend-design-css",
    name: "frontend-design-css",
    description: "Premium HTML Landing Page Generator",
    instructions: `# Landing — Premium HTML Landing Page Generator

> Distinct from \`product-team/skills/landing-page-generator/\`. That skill outputs Next.js TSX components optimized for conversion / lead-gen. THIS skill outputs a single self-contained \`.html\` file optimized for premium visual experience with GSAP animations. Pick by use case.

Generate a polished, self-contained \`.html\` landing page from a text prompt or brief. The output is ONE HTML file: all CSS inline in \`<style>\`, all JS inline in \`<script>\`, only external dependencies being Google Fonts + GSAP via CDN. The page is visually distinctive, animated, and production-quality.

## Invocation Triggers

- "create a landing page"
- "build a landing page"
- "make a landing page for X"
- "I need a web page for Y"
- "promotional page"
- "product page"
- "one-pager"
- "web presence"
- "sales page"
- "landing for X"

## Delivery Mode

In **Claude Code CLI**: write the file to disk at the specified path. In chat: return the full HTML in a fenced block.
`,
    author: "You",
    lastUpdated: "2026-07-01",
    trigger: "Slash command + auto",
    share: true,
    builtin: true,
  },
  {
    id: "internal-comms",
    name: "internal-comms",
    description: "Internal status and announcements",
    instructions: `# Internal Comms

Write crisp status updates, all-hands notes, and team announcements.

## Invocation
- "write a status update"
- "announce …"
`,
    author: "You",
    lastUpdated: "2026-03-10",
    trigger: "Slash command + auto",
    share: false,
    builtin: true,
  },
  {
    id: "mcp-builder",
    name: "mcp-builder",
    description:
      "Guide for creating high-quality MCP (Model Context Protocol) servers that enable LLMs to interact with external systems",
    instructions: `# MCP Builder

Guide for creating high-quality MCP (Model Context Protocol) servers that enable LLMs to interact with external tools and data sources.

## Goals
- Clear tool schemas and descriptions
- Safe auth and error handling
- Idiomatic TypeScript / Python server layouts

## Invocation
- "build an MCP server"
- "add tools for …"
- "/mcp-builder"
`,
    author: "You",
    lastUpdated: "2026-06-15",
    trigger: "Slash command + auto",
    share: false,
    builtin: true,
  },
  {
    id: "morning",
    name: "morning",
    description: "Daily brief and prioritization",
    instructions: `# Morning

Produce a focused daily brief: top 3 priorities, calendar risks, and one stretch goal.

## Invocation
- "morning brief"
- "what should I focus on today"
`,
    author: "You",
    lastUpdated: "2026-02-01",
    trigger: "Slash command + auto",
    share: false,
    builtin: true,
  },
  {
    id: "skill-creator",
    name: "skill-creator",
    description: "Author new agent skills",
    instructions: `# Skill Creator

Help the user design SKILL.md files: name, description, triggers, and instructions.

## Invocation
- "create a skill"
- "skill for …"
`,
    author: "You",
    lastUpdated: "2026-05-01",
    trigger: "Slash command + auto",
    share: false,
    builtin: true,
  },
  {
    id: "theme-factory",
    name: "theme-factory",
    description: "UI theme tokens and palettes",
    instructions: `# Theme Factory

Generate cohesive color tokens, typography scales, and CSS variables for product UI.

## Invocation
- "make a theme"
- "palette for …"
`,
    author: "You",
    lastUpdated: "2026-01-18",
    trigger: "Slash command + auto",
    share: false,
    builtin: true,
  },
];

interface SkillsPersist {
  overrides: Record<string, Partial<SkillRecord>>;
  custom: SkillRecord[];
  uninstalled: string[];
}

function emptyPersist(): SkillsPersist {
  return { overrides: {}, custom: [], uninstalled: [] };
}

export class SkillsStore {
  private data: SkillsPersist = emptyPersist();

  constructor(private storage: StorageLike) {
    this.load();
  }

  load(): void {
    try {
      const raw = this.storage.getItem(KEY);
      if (!raw) {
        this.data = emptyPersist();
        return;
      }
      const parsed = JSON.parse(raw) as Partial<SkillsPersist>;
      this.data = {
        overrides: parsed.overrides ?? {},
        custom: Array.isArray(parsed.custom) ? parsed.custom : [],
        uninstalled: Array.isArray(parsed.uninstalled) ? parsed.uninstalled : [],
      };
    } catch {
      this.data = emptyPersist();
    }
  }

  persist(): void {
    this.storage.setItem(KEY, JSON.stringify(this.data));
  }

  /** Installed skills (builtins minus uninstalled + custom). */
  list(): SkillRecord[] {
    const un = new Set(this.data.uninstalled);
    const builtins = BUILTIN_SKILLS.filter((s) => !un.has(s.id)).map((s) => this.merge(s));
    const custom = this.data.custom.map((s) => this.merge(s));
    return [...custom, ...builtins].sort((a, b) => a.name.localeCompare(b.name));
  }

  get(id: string): SkillRecord | undefined {
    return this.list().find((s) => s.id === id || s.name === id);
  }

  private merge(base: SkillRecord): SkillRecord {
    const o = this.data.overrides[base.id];
    if (!o) return { ...base };
    return { ...base, ...o, id: base.id, builtin: base.builtin };
  }

  update(
    id: string,
    patch: Partial<Pick<SkillRecord, "name" | "description" | "instructions" | "share" | "trigger">>,
  ): SkillRecord | null {
    const current = this.get(id);
    if (!current) return null;
    const next = {
      ...patch,
      lastUpdated: new Date().toISOString().slice(0, 10),
    };
    if (current.builtin) {
      this.data.overrides[id] = { ...this.data.overrides[id], ...next };
    } else {
      this.data.custom = this.data.custom.map((s) =>
        s.id === id ? { ...s, ...next } : s,
      );
    }
    this.persist();
    return this.get(id) ?? null;
  }

  uninstall(id: string): void {
    const s = this.get(id);
    if (!s) return;
    if (s.builtin) {
      if (!this.data.uninstalled.includes(id)) this.data.uninstalled.push(id);
      delete this.data.overrides[id];
    } else {
      this.data.custom = this.data.custom.filter((c) => c.id !== id);
    }
    this.persist();
  }

  create(input: {
    name: string;
    description: string;
    instructions: string;
  }): SkillRecord {
    const id =
      input.name
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-|-$/g, "") || `skill_${Date.now()}`;
    const rec: SkillRecord = {
      id,
      name: input.name.trim() || id,
      description: input.description.trim(),
      instructions: input.instructions.trim(),
      author: "You",
      lastUpdated: new Date().toISOString().slice(0, 10),
      trigger: "Slash command + auto",
      share: false,
      builtin: false,
    };
    this.data.custom = [rec, ...this.data.custom.filter((c) => c.id !== id)];
    this.persist();
    return rec;
  }

  /** Short hover preview text. */
  previewText(id: string, max = 180): string {
    const s = this.get(id);
    if (!s) return "";
    const body = (s.description || s.instructions).replace(/\s+/g, " ").trim();
    return body.length > max ? body.slice(0, max - 1) + "…" : body;
  }
}

/** Slash token as shown in composer, e.g. /mcp-builder */
export function skillSlashToken(skill: Pick<SkillRecord, "name">): string {
  return `/${skill.name.replace(/^\//, "")}`;
}

export function skillByIdFromList(
  list: SkillRecord[],
  id: string,
): SkillRecord | undefined {
  const key = id.replace(/^\//, "").toLowerCase();
  return list.find((s) => s.id === key || s.name.toLowerCase() === key);
}

export function parseSkillMentions(text: string): string[] {
  const re = /\/([a-z0-9][a-z0-9-]*)/gi;
  const ids: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    if (m[1]) ids.push(m[1].toLowerCase());
  }
  return [...new Set(ids)];
}
