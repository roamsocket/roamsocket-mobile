/**
 * Per-session agent config loader (Claude Code–compatible hierarchy).
 *
 * When a Code (phone) or TUI (CLI) session starts, we merge instructions,
 * skills, env, and project MCP from three scopes:
 *
 *   1. **Global / user** — `~/.claude/` (and `~/.anyprov/` for product parity)
 *   2. **Workspace / project** — repo root files + `.claude/` / `.anyprov/`
 *   3. **Folder** — `CLAUDE.md` / `CLAUDE.local.md` / nested config walking
 *      from the session workdir up the directory tree
 *
 * Load order for instructions is broadest → most specific (user, then
 * ancestors from the filesystem root side down to workdir), matching
 * Claude Code: https://code.claude.com/docs/en/memory
 *
 * Also accepts RoamSocket `AGENTS.md` / `.anyprov/` layouts used by this app.
 */
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export type InstructionScope = 'user' | 'project' | 'folder' | 'local';

export interface InstructionSource {
  /** Absolute path to the file. */
  path: string;
  scope: InstructionScope;
  /** Human label for /memory (relative when under workdir). */
  label: string;
  content: string;
}

export interface ProjectConfig {
  env: Record<string, string>;
  mcpServers: Array<{
    name: string;
    type: string;
    command?: string;
    args?: string[];
    env?: Record<string, string>;
    url?: string;
  }>;
  /**
   * Merged instruction markdown (headers + bodies), broadest first.
   * Null when nothing was found.
   */
  instructionsMd: string | null;
  /** Individual instruction files that contributed to `instructionsMd`. */
  instructionSources: InstructionSource[];
  skills: Array<{ name: string; content: string; source: string }>;
}

const EMPTY: ProjectConfig = {
  env: {},
  mcpServers: [],
  instructionsMd: null,
  instructionSources: [],
  skills: [],
};

const HOME = os.homedir();

/** Prefer `.claude` then `.anyprov` for product + Claude Code interop. */
const PROJECT_CONFIG_DIR_NAMES = ['.claude', '.anyprov'] as const;

/** Max depth for `@path` imports inside instruction files. */
const MAX_IMPORT_DEPTH = 4;

/** Cap individual instruction files so a huge CLAUDE.md cannot blow the prompt. */
const MAX_INSTRUCTION_CHARS = 120_000;

export interface ReadProjectConfigOptions {
  /** Override home for tests. */
  homeDir?: string;
  /** Skip user/global scope (tests). */
  skipUser?: boolean;
}

/** Read project config for a session workdir and return a merged view. */
export async function readProjectConfig(
  workdir: string,
  opts: ReadProjectConfigOptions = {}
): Promise<ProjectConfig> {
  const root = path.resolve(workdir);
  const homeDir = opts.homeDir ?? HOME;

  const instructionSources: InstructionSource[] = [];
  const seenInstructionPaths = new Set<string>();
  const skillsByName = new Map<string, { name: string; content: string; source: string }>();
  let env: Record<string, string> = {};
  const mcpByName = new Map<string, ProjectConfig['mcpServers'][number]>();

  const userConfigDirs = opts.skipUser
    ? []
    : [path.join(homeDir, '.claude'), path.join(homeDir, '.anyprov')];

  // ── 1. User / global scope ──────────────────────────────────────────────
  for (const dir of userConfigDirs) {
    await collectInstructionsFromConfigDir(
      dir,
      'user',
      root,
      instructionSources,
      seenInstructionPaths
    );
    // User-level CLAUDE.md lives directly in ~/.claude/CLAUDE.md
    await pushInstructionFile(
      path.join(dir, 'CLAUDE.md'),
      'user',
      root,
      instructionSources,
      seenInstructionPaths
    );
    await collectRulesDir(
      path.join(dir, 'rules'),
      'user',
      root,
      instructionSources,
      seenInstructionPaths
    );
    await collectSkillsDir(path.join(dir, 'skills'), skillsByName);
    env = { ...env, ...(await readSettingsEnv(path.join(dir, 'settings.json'))) };
  }

  // ── 2. Directory walk: ancestors → workdir (folder + workspace) ─────────
  const chain = await directoryChain(root, homeDir);
  // Claude Code orders content from filesystem-root side down to cwd.
  // `directoryChain` returns workdir → … → top; reverse for load order.
  const loadOrder = [...chain].reverse();

  for (const dir of loadOrder) {
    const isWorkdir = path.resolve(dir) === root;
    const scope: InstructionScope = isWorkdir ? 'project' : 'folder';

    // Root-level instruction files in this directory
    for (const name of ['AGENTS.md', 'Agents.md', 'agents.md', 'CLAUDE.md', 'CLAUDE.local.md']) {
      const scopeForFile: InstructionScope = name === 'CLAUDE.local.md' ? 'local' : scope;
      await pushInstructionFile(
        path.join(dir, name),
        scopeForFile,
        root,
        instructionSources,
        seenInstructionPaths
      );
    }

    // Nested project config dirs (.claude / .anyprov)
    for (const confName of PROJECT_CONFIG_DIR_NAMES) {
      const confDir = path.join(dir, confName);
      if (!(await isDirectory(confDir))) continue;

      await collectInstructionsFromConfigDir(
        confDir,
        scope,
        root,
        instructionSources,
        seenInstructionPaths
      );
      await collectRulesDir(
        path.join(confDir, 'rules'),
        scope,
        root,
        instructionSources,
        seenInstructionPaths
      );
      await collectSkillsDir(path.join(confDir, 'skills'), skillsByName);

      // settings: project then local (local wins) — only meaningful near workspace
      env = { ...env, ...(await readSettingsEnv(path.join(confDir, 'settings.json'))) };
      env = { ...env, ...(await readSettingsEnv(path.join(confDir, 'settings.local.json'))) };

      for (const mcp of await readMcpJson(path.join(confDir, 'mcp.json'))) {
        mcpByName.set(mcp.name, mcp);
      }
    }

    // Project-root `.mcp.json` (Claude Code convention)
    for (const mcp of await readMcpJson(path.join(dir, '.mcp.json'))) {
      mcpByName.set(mcp.name, mcp);
    }
  }

  // Expand @imports in instruction bodies (relative to each file)
  const expanded: InstructionSource[] = [];
  for (const src of instructionSources) {
    const content = await expandImports(
      src.content,
      path.dirname(src.path),
      0,
      new Set([src.path])
    );
    expanded.push({ ...src, content });
  }

  const instructionsMd = formatInstructions(expanded);
  const skills = [...skillsByName.values()];

  return {
    env,
    mcpServers: [...mcpByName.values()],
    instructionsMd,
    instructionSources: expanded,
    skills,
  };
}

/** Format instruction sources for injection / display. */
export function formatInstructions(sources: InstructionSource[]): string | null {
  if (sources.length === 0) return null;
  const parts: string[] = [];
  for (const s of sources) {
    const body = s.content.trim();
    if (!body) continue;
    parts.push(`### ${s.label} (${s.scope})\n\n${body}`);
  }
  return parts.length > 0 ? parts.join('\n\n') : null;
}

/**
 * Human-readable dump of loaded memory files (used by CLI `/memory`).
 */
export async function describeProjectMemory(
  workdir: string,
  opts: ReadProjectConfigOptions = {}
): Promise<string> {
  const cfg = await readProjectConfig(workdir, opts);
  if (cfg.instructionSources.length === 0 && cfg.skills.length === 0) {
    return [
      'No instruction files loaded.',
      '',
      'RoamSocket looks for Claude Code–compatible memory at:',
      '  • Global:  ~/.claude/CLAUDE.md, ~/.claude/rules/, ~/.claude/skills/',
      '  • Project: ./CLAUDE.md, ./AGENTS.md, ./.claude/CLAUDE.md, ./.claude/rules/',
      '  • Folder:  CLAUDE.md / CLAUDE.local.md walking up from the workdir',
      '',
      'Run /init to create a starter AGENTS.md in this workdir.',
    ].join('\n');
  }

  const lines: string[] = [];
  lines.push(`Workdir: ${path.resolve(workdir)}`);
  lines.push(`Instruction files (${cfg.instructionSources.length}):`);
  for (const s of cfg.instructionSources) {
    const chars = s.content.length;
    lines.push(`  • [${s.scope}] ${s.label}  (${chars} chars)`);
  }
  if (cfg.skills.length > 0) {
    lines.push('');
    lines.push(`Skills (${cfg.skills.length}):`);
    for (const sk of cfg.skills) {
      lines.push(`  • ${sk.name}  ← ${sk.source}`);
    }
  }
  if (Object.keys(cfg.env).length > 0) {
    lines.push('');
    lines.push(
      `Env from settings (${Object.keys(cfg.env).length} keys): ${Object.keys(cfg.env).join(', ')}`
    );
  }
  if (cfg.mcpServers.length > 0) {
    lines.push('');
    lines.push(`Project MCP servers: ${cfg.mcpServers.map((m) => m.name).join(', ')}`);
  }
  lines.push('');
  lines.push('── Preview (truncated) ──');
  const preview = (cfg.instructionsMd ?? '').trim();
  lines.push(preview.length > 6000 ? `${preview.slice(0, 6000)}\n…` : preview || '(empty)');
  return lines.join('\n');
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Workdir → parents up to (and including) the user's home directory.
 * Monorepo parents under `$HOME/...` are included; we stop at home so
 * `/Users` / `/` are not scanned. User-scope `~/.claude` is loaded
 * separately and de-duped via `seenInstructionPaths`.
 *
 * If workdir is outside home (e.g. `/tmp/clone`), walk up to the
 * filesystem root with a depth cap instead.
 */
async function directoryChain(workdir: string, homeDir: string): Promise<string[]> {
  const out: string[] = [];
  let cur = path.resolve(workdir);
  const home = path.resolve(homeDir);
  const fsRoot = path.parse(cur).root;
  const underHome = cur === home || cur.startsWith(home + path.sep);

  for (let i = 0; i < 48; i++) {
    out.push(cur);
    if (cur === fsRoot) break;
    if (underHome && cur === home) break;
    const parent = path.dirname(cur);
    if (parent === cur) break;
    cur = parent;
  }
  return out;
}

async function isDirectory(p: string): Promise<boolean> {
  try {
    const st = await fs.stat(p);
    return st.isDirectory();
  } catch {
    return false;
  }
}

async function readMaybeFile(p: string): Promise<string | null> {
  try {
    const text = await fs.readFile(p, 'utf8');
    return text.length > MAX_INSTRUCTION_CHARS
      ? text.slice(0, MAX_INSTRUCTION_CHARS) + '\n\n<!-- truncated -->\n'
      : text;
  } catch {
    return null;
  }
}

async function pushInstructionFile(
  filePath: string,
  scope: InstructionScope,
  workdir: string,
  out: InstructionSource[],
  seen: Set<string>
): Promise<void> {
  const resolved = path.resolve(filePath);
  if (seen.has(resolved)) return;
  const raw = await readMaybeFile(resolved);
  if (raw == null) return;
  // Skip empty / whitespace-only
  if (!raw.trim()) {
    seen.add(resolved);
    return;
  }
  seen.add(resolved);
  out.push({
    path: resolved,
    scope,
    label: labelFor(resolved, workdir),
    content: stripHtmlComments(raw),
  });
}

function labelFor(absPath: string, workdir: string): string {
  const home = HOME;
  if (absPath.startsWith(home + path.sep) || absPath === home) {
    return '~' + absPath.slice(home.length);
  }
  const rel = path.relative(workdir, absPath);
  if (rel && !rel.startsWith('..') && !path.isAbsolute(rel)) return rel;
  return absPath;
}

/** Strip block-level HTML comments (Claude Code does this for CLAUDE.md). */
function stripHtmlComments(text: string): string {
  // Preserve comments inside fenced code blocks by a simple split.
  const parts = text.split(/(```[\s\S]*?```)/g);
  return parts
    .map((part, i) => {
      if (i % 2 === 1) return part; // code fence
      return part.replace(/<!--[\s\S]*?-->/g, '');
    })
    .join('');
}

async function collectInstructionsFromConfigDir(
  confDir: string,
  scope: InstructionScope,
  workdir: string,
  out: InstructionSource[],
  seen: Set<string>
): Promise<void> {
  if (!(await isDirectory(confDir))) return;
  for (const name of ['AGENTS.md', 'CLAUDE.md', 'CLAUDE.local.md']) {
    const scopeForFile: InstructionScope = name === 'CLAUDE.local.md' ? 'local' : scope;
    await pushInstructionFile(path.join(confDir, name), scopeForFile, workdir, out, seen);
  }
}

async function collectRulesDir(
  rulesDir: string,
  scope: InstructionScope,
  workdir: string,
  out: InstructionSource[],
  seen: Set<string>
): Promise<void> {
  if (!(await isDirectory(rulesDir))) return;
  const files = await listMarkdownRecursive(rulesDir);
  files.sort();
  for (const file of files) {
    // Path-scoped rules (frontmatter `paths:`) are still loaded at session
    // start — our agent does not yet do on-demand rule injection.
    await pushInstructionFile(file, scope, workdir, out, seen);
  }
}

async function listMarkdownRecursive(dir: string): Promise<string[]> {
  const out: string[] = [];
  let entries: import('node:fs').Dirent[];
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const ent of entries) {
    if (ent.name.startsWith('.')) continue;
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) {
      out.push(...(await listMarkdownRecursive(full)));
    } else if (ent.isFile() && ent.name.endsWith('.md')) {
      out.push(full);
    }
  }
  return out;
}

async function collectSkillsDir(
  skillsDir: string,
  byName: Map<string, { name: string; content: string; source: string }>
): Promise<void> {
  let entries: string[] = [];
  try {
    entries = await fs.readdir(skillsDir);
  } catch {
    return;
  }
  for (const id of entries) {
    if (id.startsWith('.')) continue;
    const skillFile = path.join(skillsDir, id, 'SKILL.md');
    try {
      const text = await fs.readFile(skillFile, 'utf8');
      const body = text.replace(/^---\n[\s\S]*?\n---\n*/, '');
      // Later scopes (project) override earlier (user) by same skill id.
      byName.set(id, {
        name: id,
        content: body,
        source: skillFile,
      });
    } catch {
      continue;
    }
  }
}

async function readSettingsEnv(p: string): Promise<Record<string, string>> {
  try {
    const text = await fs.readFile(p, 'utf8');
    const data = JSON.parse(text) as { env?: Record<string, unknown> };
    if (data && typeof data === 'object' && data.env && typeof data.env === 'object') {
      const out: Record<string, string> = {};
      for (const [k, v] of Object.entries(data.env)) {
        if (typeof v === 'string') out[k] = v;
      }
      return out;
    }
  } catch {
    /* missing or invalid */
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

async function readMcpJson(p: string): Promise<ProjectConfig['mcpServers']> {
  try {
    const text = await fs.readFile(p, 'utf8');
    const data = JSON.parse(text) as McpFile;
    const entries = Object.entries(data.mcpServers ?? {});
    return entries.map(([name, spec]) => ({
      name,
      type: spec.type ?? 'stdio',
      command: spec.command,
      args: spec.args,
      env: spec.env,
      url: spec.url,
    }));
  } catch {
    return [];
  }
}

/**
 * Expand Claude-style `@path` imports outside code spans/fences.
 * Relative paths resolve relative to the importing file.
 */
async function expandImports(
  text: string,
  baseDir: string,
  depth: number,
  stack: Set<string>
): Promise<string> {
  if (depth >= MAX_IMPORT_DEPTH) return text;

  // Split on fenced code blocks and inline code so we don't expand inside them.
  const segments = text.split(/(```[\s\S]*?```|`[^`\n]+`)/g);
  const out: string[] = [];

  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i] ?? '';
    if (i % 2 === 1) {
      out.push(seg);
      continue;
    }
    // Match @path tokens: @./foo, @../bar, @~/x, @/abs, @foo/bar.md, @AGENTS.md
    const re = /(^|[\s(])@([~./A-Za-z0-9_-][^\s)\]}'"]*)/g;
    let last = 0;
    let m: RegExpExecArray | null;
    let rebuilt = '';
    while ((m = re.exec(seg)) !== null) {
      const prefix = m[1] ?? '';
      const ref = m[2] ?? '';
      rebuilt += seg.slice(last, m.index) + prefix;
      last = m.index + m[0].length;

      const resolved = resolveImportPath(ref, baseDir);
      if (!resolved || stack.has(resolved)) {
        rebuilt += `@${ref}`;
        continue;
      }
      const imported = await readMaybeFile(resolved);
      if (imported == null) {
        rebuilt += `@${ref}`;
        continue;
      }
      const nextStack = new Set(stack);
      nextStack.add(resolved);
      const expanded = await expandImports(
        stripHtmlComments(imported),
        path.dirname(resolved),
        depth + 1,
        nextStack
      );
      rebuilt += `\n\n<!-- import ${ref} -->\n${expanded.trim()}\n`;
    }
    rebuilt += seg.slice(last);
    out.push(rebuilt);
  }
  return out.join('');
}

function resolveImportPath(ref: string, baseDir: string): string | null {
  let p = ref.trim();
  if (!p) return null;
  // Strip trailing punctuation that often follows @refs in prose
  p = p.replace(/[.,;:]+$/, '');
  if (p.startsWith('~/')) {
    return path.resolve(HOME, p.slice(2));
  }
  if (p.startsWith('~')) {
    return path.resolve(HOME, p.slice(1));
  }
  if (path.isAbsolute(p)) return path.resolve(p);
  return path.resolve(baseDir, p);
}

// Re-export empty sentinel for tests
export const EMPTY_PROJECT_CONFIG: ProjectConfig = EMPTY;

/** @deprecated Prefer USER_CONFIG_DIRS constant usage via readProjectConfig. */
export function userClaudeDirs(homeDir: string = HOME): string[] {
  return [path.join(homeDir, '.claude'), path.join(homeDir, '.anyprov')];
}
