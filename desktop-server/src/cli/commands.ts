/**
 * Slash-command catalog + parser for the RoamSocket CLI TUI.
 *
 * Inspired by Claude Code’s command set, but only commands that make sense
 * for a BYOK local agent + phone pairing companion (no /usage, /cost, cloud
 * teleport, subscription login, etc.).
 */
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import QRCode from "qrcode";
import { listCloudModels } from "../client/list-cloud-models.js";
import { CHAT_PROVIDERS, defaultModelFor } from "../client/providers-meta.js";
import type { PermissionMode } from "../protocol.js";
import { getMetalStore } from "../metal/store.js";
import { pairPayload } from "./banner.js";
import {
  type MetalCliAction,
  getMetalCompletions,
  parseMetalArgs,
} from "./metal-cli.js";
import { loadCliSecrets, resolveApiKey } from "./secrets.js";

export type EffortLevel = "low" | "medium" | "high";

export type CliCommand =
  | { kind: "help" }
  | { kind: "clear" }
  | { kind: "compact" }
  | { kind: "quit" }
  | { kind: "mobile" }
  | { kind: "pair" }
  | { kind: "server" }
  | { kind: "permission"; mode?: PermissionMode }
  | { kind: "model"; provider?: string; model?: string }
  | { kind: "keys"; provider?: string; key?: string }
  | { kind: "effort"; effort?: EffortLevel }
  | { kind: "context" }
  | { kind: "doctor" }
  | { kind: "init" }
  | { kind: "memory" }
  | { kind: "tasks" }
  | { kind: "diff" }
  | { kind: "export" }
  | { kind: "metal"; action: MetalCliAction }
  | { kind: "unknown"; raw: string }
  /** Pass through to the agent (includes /goal and skill-style kickoffs). */
  | { kind: "agent"; text: string };

export interface SlashCommandDef {
  /** Canonical name without leading slash. */
  name: string;
  aliases?: string[];
  /** Short description for completions + help. */
  description: string;
  /** Optional usage suffix shown in help, e.g. "[condition]". */
  usage?: string;
  /**
   * When set, the command is rewritten into an agent user message.
   * `args` is everything after the command token.
   */
  toAgent?: (args: string) => string;
}

/**
 * Completions + help catalog. Order is display order.
 * Keep aliases out of the primary list when they are short helpers (/h, /q).
 */
export const SLASH_COMMANDS: SlashCommandDef[] = [
  { name: "help", aliases: ["h", "?"], description: "Show slash-command help" },
  { name: "clear", aliases: ["new", "reset"], description: "New conversation (same workdir)" },
  {
    name: "compact",
    description: "Free context — start a fresh conversation (same workdir)",
  },
  {
    name: "mobile",
    description: "Show pairing QR + 6-digit code for the iOS app",
  },
  {
    name: "pair",
    aliases: ["code"],
    description: "Show the 6-digit pairing code (no QR)",
  },
  {
    name: "server",
    aliases: ["status"],
    description: "Server port, LAN/tunnel, workdir",
  },
  {
    name: "model",
    usage: "[provider/model]",
    description: "Show or set provider/model",
  },
  {
    name: "effort",
    usage: "[low|medium|high]",
    description: "Show or set reasoning effort",
  },
  {
    name: "permission",
    aliases: ["perm", "mode", "permissions"],
    usage: "[acceptEdits|ask|plan]",
    description: "Cycle or set permission mode",
  },
  {
    name: "plan",
    description: "Switch to plan mode (read-only tools)",
  },
  {
    name: "keys",
    aliases: ["key"],
    usage: "[provider key]",
    description: "List or save a provider API key",
  },
  {
    name: "metal",
    usage: "[browse|download|use|delete|runtime|…]",
    description: "On-device Metal models — browser, download, use, runtime",
  },
  {
    name: "goal",
    usage: "[condition|clear]",
    description: "Keep working until a condition is met",
    toAgent: (args) => (args ? `/goal ${args}` : "/goal"),
  },
  {
    name: "context",
    description: "Show model, mode, workdir, tunnel, task count",
  },
  {
    name: "doctor",
    description: "Quick health check (keys, workdir, server)",
  },
  {
    name: "init",
    description: "Create a starter AGENTS.md in the workdir",
  },
  {
    name: "memory",
    description: "Show loaded instructions (global / workspace / folder .claude)",
  },
  {
    name: "tasks",
    description: "Show the agent task checklist",
  },
  {
    name: "diff",
    description: "Show git status + short diff in the workdir",
  },
  {
    name: "export",
    description: "Write the current transcript to a text file",
  },
  {
    name: "review",
    aliases: ["code-review"],
    usage: "[focus]",
    description: "Ask the agent to review the current diff",
    toAgent: (args) =>
      args
        ? `Review the current uncommitted changes with focus on: ${args}. Look for bugs, regressions, and missing tests. Summarize findings.`
        : "Review the current uncommitted changes for correctness bugs, edge cases, and cleanup. Summarize findings with severity.",
  },
  {
    name: "security-review",
    usage: "[focus]",
    description: "Ask the agent for a security-focused diff review",
    toAgent: (args) =>
      args
        ? `Security-review the current changes focusing on: ${args}. Flag injection, auth, secrets, and unsafe shell/file use.`
        : "Security-review the current uncommitted changes. Flag injection, auth gaps, secret leaks, path traversal, and unsafe commands.",
  },
  {
    name: "quit",
    aliases: ["exit", "q"],
    description: "Exit the TUI (stops the pairing server)",
  },
];

const PERMISSION_CYCLE: PermissionMode[] = ["acceptEdits", "ask", "plan"];

/** All names + aliases for lookup. */
function buildLookup(): Map<string, SlashCommandDef> {
  const map = new Map<string, SlashCommandDef>();
  for (const def of SLASH_COMMANDS) {
    map.set(def.name, def);
    for (const a of def.aliases ?? []) map.set(a, def);
  }
  return map;
}

const LOOKUP = buildLookup();

export function parseCliCommand(input: string): CliCommand {
  const text = input.trim();
  if (!text.startsWith("/")) {
    return { kind: "agent", text };
  }

  const m = text.match(/^\/([^\s]+)(?:\s+([\s\S]*))?$/);
  if (!m) return { kind: "unknown", raw: text };
  const token = (m[1] ?? "").toLowerCase();
  const arg = (m[2] ?? "").trim();
  const def = LOOKUP.get(token);

  if (!def) {
    return { kind: "unknown", raw: text };
  }

  // Agent-forward commands (goal, review, …)
  if (def.toAgent) {
    return { kind: "agent", text: def.toAgent(arg) };
  }

  switch (def.name) {
    case "help":
      return { kind: "help" };
    case "clear":
      return { kind: "clear" };
    case "compact":
      return { kind: "compact" };
    case "quit":
      return { kind: "quit" };
    case "mobile":
      return { kind: "mobile" };
    case "pair":
      return { kind: "pair" };
    case "server":
      return { kind: "server" };
    case "context":
      return { kind: "context" };
    case "doctor":
      return { kind: "doctor" };
    case "init":
      return { kind: "init" };
    case "memory":
      return { kind: "memory" };
    case "tasks":
      return { kind: "tasks" };
    case "diff":
      return { kind: "diff" };
    case "export":
      return { kind: "export" };
    case "metal":
      return { kind: "metal", action: parseMetalArgs(arg) };
    case "plan":
      return { kind: "permission", mode: "plan" };
    case "permission": {
      if (!arg) return { kind: "permission" };
      const mode = normalizePermission(arg);
      return mode ? { kind: "permission", mode } : { kind: "unknown", raw: text };
    }
    case "effort": {
      if (!arg) return { kind: "effort" };
      const effort = normalizeEffort(arg);
      return effort ? { kind: "effort", effort } : { kind: "unknown", raw: text };
    }
    case "model": {
      if (!arg) return { kind: "model" };
      const slash = arg.indexOf("/");
      if (slash > 0) {
        return {
          kind: "model",
          provider: arg.slice(0, slash).trim(),
          model: arg.slice(slash + 1).trim(),
        };
      }
      const parts = arg.split(/\s+/);
      if (parts.length >= 2) {
        return { kind: "model", provider: parts[0], model: parts.slice(1).join(" ") };
      }
      return { kind: "model", model: arg };
    }
    case "keys": {
      if (!arg) return { kind: "keys" };
      const sp = arg.indexOf(" ");
      if (sp < 0) return { kind: "keys", provider: arg };
      return {
        kind: "keys",
        provider: arg.slice(0, sp).trim(),
        key: arg.slice(sp + 1).trim(),
      };
    }
    default:
      return { kind: "unknown", raw: text };
  }
}

function normalizePermission(s: string): PermissionMode | null {
  const t = s.toLowerCase().replace(/[_-]/g, "");
  if (t === "acceptedits" || t === "accept" || t === "auto") return "acceptEdits";
  if (t === "ask" || t === "manual") return "ask";
  if (t === "plan" || t === "readonly") return "plan";
  return null;
}

function normalizeEffort(s: string): EffortLevel | null {
  const t = s.toLowerCase();
  if (t === "low" || t === "medium" || t === "high") return t;
  return null;
}

export function cyclePermissionMode(current: PermissionMode): PermissionMode {
  const i = PERMISSION_CYCLE.indexOf(current);
  return PERMISSION_CYCLE[(i + 1) % PERMISSION_CYCLE.length]!;
}

export interface SlashCompletion {
  /** Insert text including leading `/`, e.g. `/mobile` or `/model `. */
  token: string;
  description: string;
}

/** Live model ids fetched for providers that already have an API key. */
export interface ModelCompletionCatalog {
  /** Providers with a usable key (env or stored). */
  linked: string[];
  /** Models keyed by provider id. */
  byProvider: Record<string, Array<{ id: string; displayName: string }>>;
  /** True while a background refresh is in flight (optional UI hint). */
  loading?: boolean;
  fetchedAt?: number;
}

const LISTABLE_PROVIDERS = CHAT_PROVIDERS.map((p) => p.id).filter(
  (id) => id !== "localMetal",
);

/**
 * Fetch models for every provider that has a key (env or `/keys` store).
 * Used by `/model` completions so linked providers expand to real model ids.
 */
export async function loadModelCompletionCatalog(opts?: {
  mock?: boolean;
  signal?: AbortSignal;
}): Promise<ModelCompletionCatalog> {
  if (opts?.mock || process.env.APC_MOCK === "1") {
    return {
      linked: ["anthropic"],
      byProvider: {
        anthropic: [{ id: "mock", displayName: "mock (APC_MOCK)" }],
      },
      fetchedAt: Date.now(),
    };
  }

  const secrets = loadCliSecrets();
  const linked: string[] = [];
  const byProvider: ModelCompletionCatalog["byProvider"] = {};

  await Promise.all(
    LISTABLE_PROVIDERS.map(async (provider) => {
      const key = resolveApiKey(provider, secrets);
      if (!key) return;
      linked.push(provider);
      try {
        const models = await listCloudModels(provider, key, { signal: opts?.signal });
        if (models.length > 0) {
          byProvider[provider] = models.slice(0, 80).map((m) => ({
            id: m.id,
            displayName: m.displayName || m.id,
          }));
        } else {
          const fallback = defaultModelFor(provider);
          byProvider[provider] = fallback
            ? [{ id: fallback, displayName: `${fallback} (default)` }]
            : [];
        }
      } catch {
        const fallback = defaultModelFor(provider);
        byProvider[provider] = fallback
          ? [{ id: fallback, displayName: `${fallback} (default)` }]
          : [];
      }
    }),
  );

  // Downloaded on-device Metal models (no cloud key required).
  try {
    const metal = getMetalStore().listDownloaded();
    if (metal.length > 0) {
      linked.push("localMetal");
      byProvider.localMetal = metal.map((m) => ({
        id: m.hubID,
        displayName: m.displayName || m.hubID,
      }));
    }
  } catch {
    /* store unavailable */
  }

  linked.sort();
  return { linked, byProvider, fetchedAt: Date.now() };
}

export interface SlashCompletionOptions {
  /** When set, `/model` completes real models for keyed providers. */
  modelCatalog?: ModelCompletionCatalog | null;
}

/**
 * Completions while the composer starts with `/`.
 * - `/go` → `/goal`, …
 * - `/permission a` → acceptEdits / ask
 * - `/effort ` → low|medium|high
 * - `/model anthropic/` → live models when that provider has a key
 */
export function getSlashCompletions(
  input: string,
  opts?: SlashCompletionOptions,
): SlashCompletion[] {
  if (!input.startsWith("/") || input.includes("\n")) return [];

  const body = input.slice(1);
  const space = body.search(/\s/);

  // Completing the command name
  if (space < 0) {
    const q = body.toLowerCase();
    const out: SlashCompletion[] = [];
    const seen = new Set<string>();
    for (const def of SLASH_COMMANDS) {
      const names = [def.name, ...(def.aliases ?? [])];
      for (const n of names) {
        if (!n.startsWith(q)) continue;
        // Prefer canonical name once per command when query matches name
        const primary = def.name.startsWith(q) ? def.name : n;
        if (seen.has(def.name) && primary !== def.name) continue;
        if (seen.has(primary)) continue;
        seen.add(def.name);
        seen.add(primary);
        const needsSpace = Boolean(def.usage) || Boolean(def.toAgent);
        out.push({
          token: `/${primary}${needsSpace && q.length >= primary.length ? " " : ""}`,
          description: def.description,
        });
        break;
      }
    }
    return out.slice(0, 20);
  }

  const cmdToken = body.slice(0, space).toLowerCase();
  const argPart = body.slice(space + 1);
  const def = LOOKUP.get(cmdToken);
  if (!def) return [];

  if (def.name === "permission" || def.name === "plan") {
    return completeFromList(argPart, ["acceptEdits", "ask", "plan"], input);
  }
  if (def.name === "effort") {
    return completeFromList(argPart, ["low", "medium", "high"], input);
  }
  if (def.name === "goal") {
    return completeFromList(argPart, ["clear", "stop"], input).concat(
      argPart === ""
        ? [{ token: "/goal ", description: "Type a completion condition…" }]
        : [],
    );
  }
  if (def.name === "model") {
    return completeModelArg(argPart, input, opts?.modelCatalog ?? null);
  }
  if (def.name === "metal") {
    return getMetalCompletions(argPart, input);
  }
  if (def.name === "keys") {
    return completeFromList(
      argPart,
      ["anthropic ", "openai ", "google ", "groq ", "openrouter ", "xai ", "mistral ", "minimax "],
      input,
    );
  }
  return [];
}

/**
 * `/model` argument completions:
 * - linked providers first (those with keys)
 * - once `provider/` or `provider ` is chosen, list fetched model ids
 */
export function completeModelArg(
  argPart: string,
  fullInput: string,
  catalog: ModelCompletionCatalog | null,
): SlashCompletion[] {
  const prefix = fullInput.slice(0, fullInput.length - argPart.length);
  const linked = catalog?.linked ?? [];
  const byProvider = catalog?.byProvider ?? {};

  const slash = argPart.indexOf("/");
  if (slash >= 0) {
    const prov = argPart.slice(0, slash).trim().toLowerCase();
    const modelQ = argPart.slice(slash + 1).toLowerCase();
    return modelCompletionsForProvider(prov, modelQ, prefix, byProvider, linked, catalog?.loading);
  }

  // "anthropic claude…" or "anthropic " (trailing space)
  const trimmedEnd = argPart.replace(/\s+$/, "");
  const hasTrailingSpace = argPart.length > 0 && /\s$/.test(argPart);
  const spaceParts = trimmedEnd.split(/\s+/).filter(Boolean);
  if (spaceParts.length >= 2 || (spaceParts.length === 1 && hasTrailingSpace)) {
    const prov = (spaceParts[0] ?? "").toLowerCase();
    const modelQ = spaceParts.slice(1).join(" ").toLowerCase();
    return modelCompletionsForProvider(prov, modelQ, prefix, byProvider, linked, catalog?.loading);
  }

  // Provider-level completion
  const q = argPart.toLowerCase().trim();
  const providerPool = linked.length > 0 ? linked : [...LISTABLE_PROVIDERS];

  // Exact provider match → jump straight to its models
  if (q && (linked.includes(q) || byProvider[q])) {
    return modelCompletionsForProvider(q, "", prefix, byProvider, linked, catalog?.loading);
  }

  const hits = providerPool.filter((p) => p.startsWith(q) || q === "");
  if (hits.length === 0 && q) {
    // Partial model id without provider: search all linked catalogs
    return searchAllModels(q, prefix, byProvider).slice(0, 12);
  }

  return hits.slice(0, 12).map((p) => {
    const models = byProvider[p] ?? [];
    const n = models.length;
    const linkedHint = linked.includes(p);
    let description: string;
    if (n > 0) description = `${n} model${n === 1 ? "" : "s"}`;
    else if (catalog?.loading && linkedHint) description = "loading models…";
    else if (linkedHint) description = "linked provider";
    else description = "link with /keys first";
    return {
      token: `${prefix}${p}/`,
      description,
    };
  });
}

function modelCompletionsForProvider(
  prov: string,
  modelQ: string,
  prefix: string,
  byProvider: ModelCompletionCatalog["byProvider"],
  linked: string[],
  loading?: boolean,
): SlashCompletion[] {
  const models = byProvider[prov] ?? [];
  if (models.length === 0) {
    if (loading && linked.includes(prov)) {
      return [{ token: `${prefix}${prov}/`, description: "loading models…" }];
    }
    if (!linked.includes(prov)) {
      return [
        {
          token: `${prefix}${prov}/`,
          description: `no key — /keys ${prov} <key>`,
        },
      ];
    }
    return [
      {
        token: `${prefix}${prov}/`,
        description: "no models returned (check key / network)",
      },
    ];
  }

  return models
    .filter(
      (m) =>
        !modelQ ||
        m.id.toLowerCase().includes(modelQ) ||
        m.displayName.toLowerCase().includes(modelQ),
    )
    .slice(0, 14)
    .map((m) => ({
      token: `${prefix}${prov}/${m.id}`,
      description: m.displayName !== m.id ? m.displayName : "model",
    }));
}

function searchAllModels(
  q: string,
  prefix: string,
  byProvider: ModelCompletionCatalog["byProvider"],
): SlashCompletion[] {
  const out: SlashCompletion[] = [];
  for (const [prov, models] of Object.entries(byProvider)) {
    for (const m of models) {
      if (m.id.toLowerCase().includes(q) || m.displayName.toLowerCase().includes(q)) {
        out.push({
          token: `${prefix}${prov}/${m.id}`,
          description: m.displayName !== m.id ? `${prov} · ${m.displayName}` : prov,
        });
      }
      if (out.length >= 14) return out;
    }
  }
  return out;
}

function completeFromList(
  partial: string,
  options: string[],
  fullInput: string,
): SlashCompletion[] {
  const p = partial.toLowerCase();
  const prefix = fullInput.slice(0, fullInput.length - partial.length);
  return options
    .filter((o) => o.toLowerCase().startsWith(p))
    .slice(0, 8)
    .map((o) => ({
      token: `${prefix}${o}`,
      description: o.trim(),
    }));
}

/** Apply the selected completion (Tab). */
export function applySlashCompletion(input: string, completionToken: string): string {
  return completionToken;
}

export function formatHelpText(): string {
  const lines = [
    "RoamSocket CLI — slash commands",
    "",
    "Type / to filter. Tab accepts the highlighted completion.",
    "",
  ];
  for (const def of SLASH_COMMANDS) {
    const usage = def.usage ? ` ${def.usage}` : "";
    const alias =
      def.aliases && def.aliases.length > 0
        ? `  (${def.aliases.map((a) => `/${a}`).join(", ")})`
        : "";
    const head = `/${def.name}${usage}`.padEnd(28);
    lines.push(`  ${head}${def.description}${alias}`);
  }
  lines.push("");
  lines.push("  Esc                Interrupt running agent");
  lines.push("  Enter              Send / run command");
  lines.push("  Tab                Accept slash completion");
  lines.push("  Ctrl+C             Quit");
  lines.push("");
  lines.push("Phone pairs with this process while you code here.");
  lines.push("Terminal = cwd agent; phone = cloned repo (independent).");
  return lines.join("\n");
}

/** @deprecated use formatHelpText — kept for existing imports */
export const HELP_TEXT = formatHelpText();

// ---------------------------------------------------------------------------
// Command helpers used by the TUI
// ---------------------------------------------------------------------------

export function formatPairCode(code: string): string {
  const d = code.replace(/\D/g, "").padStart(6, "0").slice(0, 6);
  return d.split("").join(" ");
}

/** Full QR + code card for `/mobile` (ASCII QR for the terminal). */
export async function buildMobilePairingDisplay(opts: {
  host: string;
  port: number;
  pairingCode: string;
  publicUrl?: string | null;
}): Promise<string> {
  const payload = pairPayload(opts.host, opts.port, opts.pairingCode, opts.publicUrl);
  const digits = opts.pairingCode.replace(/\D/g, "").padStart(6, "0").slice(0, 6);
  const spaced = digits.split("").join("  ");
  const lines: string[] = [
    "RoamSocket — pair phone",
    "",
    `  Code:  ${spaced}`,
    `  URL:   ${payload.host}`,
    "",
    "Scan with RoamSocket → Pair server → Scan QR",
    "",
  ];
  try {
    const qr = await QRCode.toString(JSON.stringify(payload), {
      type: "terminal",
      small: true,
      errorCorrectionLevel: "M",
    });
    lines.push(qr.trimEnd());
  } catch (err) {
    lines.push(`(QR unavailable: ${(err as Error).message})`);
  }
  lines.push("");
  lines.push(`Payload: ${JSON.stringify(payload)}`);
  return lines.join("\n");
}

/**
 * Sync snapshot of instruction files in the workdir only (legacy helper).
 * Prefer `describeProjectMemory` for the full global/workspace/folder view.
 */
export function readProjectMemory(workdir: string): string {
  const candidates = [
    "AGENTS.md",
    "CLAUDE.md",
    "CLAUDE.local.md",
    "Agents.md",
    "agents.md",
    path.join(".claude", "CLAUDE.md"),
    path.join(".claude", "AGENTS.md"),
    path.join(".anyprov", "CLAUDE.md"),
    path.join(".anyprov", "AGENTS.md"),
  ];
  const found: string[] = [];
  for (const name of candidates) {
    const p = path.join(workdir, name);
    if (!existsSync(p)) continue;
    try {
      const body = readFileSync(p, "utf8");
      const preview = body.length > 4000 ? `${body.slice(0, 4000)}\n…` : body;
      found.push(`── ${name} ──\n${preview.trim() || "(empty)"}`);
    } catch {
      found.push(`── ${name} ──\n(unreadable)`);
    }
  }
  if (found.length === 0) {
    return "No AGENTS.md / CLAUDE.md in this workdir. Run /memory for full global + folder scan, or /init to create one.";
  }
  return found.join("\n\n");
}

/** Full hierarchical memory report (global + workspace + folder). */
export { describeProjectMemory } from "../project/config.js";

export function writeAgentsInit(workdir: string): { path: string; created: boolean } {
  const target = path.join(workdir, "AGENTS.md");
  if (existsSync(target)) {
    return { path: target, created: false };
  }
  const stub = `# AGENTS.md

Project instructions for coding agents (RoamSocket, Claude Code, etc.).

## What this repo is

<!-- one paragraph -->

## Commands

\`\`\`bash
# install / test / lint
\`\`\`

## Conventions

- Prefer small, focused diffs
- Match existing style

## Do not

- Commit secrets
- Hand-edit generated files without regenerating
`;
  writeFileSync(target, stub, "utf8");
  return { path: target, created: true };
}

export function gitDiffSummary(workdir: string): string {
  const status = spawnSync("git", ["status", "--short"], {
    cwd: workdir,
    encoding: "utf8",
    maxBuffer: 2_000_000,
  });
  if (status.error || status.status !== 0) {
    return status.stderr?.trim() || "Not a git repository (or git unavailable).";
  }
  const st = (status.stdout || "").trim() || "(clean)";
  const diff = spawnSync("git", ["diff", "--stat", "HEAD"], {
    cwd: workdir,
    encoding: "utf8",
    maxBuffer: 2_000_000,
  });
  const stat = (diff.stdout || "").trim();
  const unstaged = spawnSync("git", ["diff", "--stat"], {
    cwd: workdir,
    encoding: "utf8",
    maxBuffer: 2_000_000,
  });
  const u = (unstaged.stdout || "").trim();
  const parts = [`git status:\n${st}`];
  if (stat) parts.push(`\nvs HEAD:\n${stat}`);
  if (u && u !== stat) parts.push(`\nunstaged:\n${u}`);
  return parts.join("\n");
}
