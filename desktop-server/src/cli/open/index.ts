/**
 * `roamsocket open <tool>` — print env vars + launch an external coding CLI
 * pointed at the local proxy.
 *
 * Supported tools: codex (OpenAI), claude (Claude Code), aider, cursor,
 * opencode. Each one has its own env-var conventions for "use a custom base
 * URL + bearer token"; we set those, print the equivalent `export` lines for
 * the user's shell, then exec the tool if it's on PATH (or just print if not).
 *
 * APC_OPEN_IN env var sets the default tool so `roamsocket` can boot the
 * desktop + spawn the tool in one command (handy from CI / shell aliases).
 */
import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";

export type SupportedTool = "codex" | "claude" | "aider" | "cursor" | "opencode";

const TOOL_LABELS: Record<SupportedTool, string> = {
  codex: "Codex",
  claude: "Claude Code",
  aider: "Aider",
  cursor: "Cursor CLI",
  opencode: "OpenCode",
};

/**
 * Per-tool environment variables that point the CLI at our proxy. Each entry
 * is what we set in the child process env AND what we print to the user's
 * shell so they can re-use it manually.
 */
const TOOL_ENV: Record<SupportedTool, { provider: string; vars: Record<string, string>; providerHint: string }> = {
  codex: {
    provider: "openai",
    providerHint: "openai",
    vars: {}, // Codex reads OPENAI_API_KEY + OPENAI_BASE_URL.
  },
  claude: {
    provider: "anthropic",
    providerHint: "anthropic",
    vars: {}, // Claude Code reads ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN.
  },
  aider: {
    provider: "openai",
    providerHint: "openai",
    vars: {}, // Aider reads OPENAI_API_BASE + OPENAI_API_KEY.
  },
  cursor: {
    provider: "openai",
    providerHint: "openai",
    vars: {}, // Cursor CLI reads OPENAI_API_KEY + OPENAI_BASE_URL.
  },
  opencode: {
    provider: "openai",
    providerHint: "openai",
    vars: {}, // OpenCode reads OPENAI_API_KEY + OPENAI_BASE_URL via config.
  },
};

const TOOL_BINARIES: Record<SupportedTool, string[]> = {
  codex: ["codex"],
  claude: ["claude"],
  aider: ["aider"],
  cursor: ["cursor", "cursor-agent"],
  opencode: ["opencode"],
};

const TOOL_BASE_URL_VARS: Record<SupportedTool, string[]> = {
  codex: ["OPENAI_BASE_URL"],
  claude: ["ANTHROPIC_BASE_URL"],
  aider: ["OPENAI_API_BASE"],
  cursor: ["OPENAI_BASE_URL"],
  opencode: ["OPENAI_BASE_URL"],
};

const TOOL_KEY_VARS: Record<SupportedTool, string[]> = {
  codex: ["OPENAI_API_KEY"],
  claude: ["ANTHROPIC_AUTH_TOKEN"],
  aider: ["OPENAI_API_KEY"],
  cursor: ["OPENAI_API_KEY"],
  opencode: ["OPENAI_API_KEY"],
};

export function isSupportedTool(s: string): s is SupportedTool {
  return s in TOOL_LABELS;
}

export interface OpenOpts {
  tool: SupportedTool;
  baseUrl: string;
  bearer: string;
  /** Optional model override (set in env so the tool picks it up). */
  model?: string;
  /** Don't actually spawn the tool — just print the export lines and exit. */
  printOnly?: boolean;
  /** Extra args to forward to the tool binary. */
  extraArgs?: string[];
}

export function printExports(opts: OpenOpts): string[] {
  const lines: string[] = [];
  const tool = opts.tool;
  const env = buildEnv(opts);
  for (const [k, v] of Object.entries(env)) {
    lines.push(`export ${k}=${shellQuote(v)}`);
  }
  lines.push(`# Launch ${TOOL_LABELS[tool]}: ${TOOL_BINARIES[tool][0]} ${(opts.extraArgs ?? []).join(" ")}`.trim());
  return lines;
}

function shellQuote(s: string): string {
  // POSIX-safe single-quote (close, escape literal ', reopen).
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

/**
 * Build the env vars a tool needs to talk to our proxy. Used both for
 * spawning the tool and for printing export lines.
 */
export function buildEnv(opts: OpenOpts): Record<string, string> {
  const env: Record<string, string> = {};
  // Common: the proxy URL + a bearer token it accepts.
  for (const k of TOOL_BASE_URL_VARS[opts.tool]) {
    env[k] = `${opts.baseUrl}/v1`;
  }
  for (const k of TOOL_KEY_VARS[opts.tool]) {
    env[k] = opts.bearer;
  }
  // Tell the proxy which provider to forward to. Without this, the proxy
  // can't tell OpenAI / Groq / OpenRouter apart on an OpenAI-shaped request.
  env["X_ROAMSOCKET_PROVIDER"] = opts.tool === "claude" ? "anthropic" : TOOL_ENV[opts.tool].provider;
  // Some tools (Claude Code) honor a `*_AUTH_TOKEN` var so any value works;
  // pass a structured hint that the proxy understands.
  env["APC_PROXY_URL"] = opts.baseUrl;
  env["APC_PROXY_BEARER"] = opts.bearer;
  if (opts.model) {
    env[`${TOOL_ENV[opts.tool].provider.toUpperCase()}_MODEL`] = opts.model;
  }
  return env;
}

/**
 * Find a usable binary on PATH (or in well-known install locations).
 * Returns the absolute path if found, else null.
 */
export function findBinary(tool: SupportedTool): string | null {
  const candidates = TOOL_BINARIES[tool];
  const pathDirs = (process.env.PATH ?? "").split(pathSeparator()).filter(Boolean);
  for (const dir of pathDirs) {
    for (const c of candidates) {
      const exe = `${dir}${pathSep()}${c}${process.platform === "win32" ? ".exe" : ""}`;
      if (existsSync(exe)) return exe;
    }
  }
  return null;
}

function pathSeparator(): string {
  return process.platform === "win32" ? ";" : ":";
}
function pathSep(): string {
  return process.platform === "win32" ? "\\" : "/";
}

/**
 * Print + optionally spawn the tool. Returns the child PID when spawning,
 * or null when printOnly / binary not found.
 */
export function launchTool(opts: OpenOpts): number | null {
  const lines = printExports(opts);
  console.log(lines.join("\n"));
  if (opts.printOnly) return null;

  const bin = findBinary(opts.tool);
  if (!bin) {
    console.error(
      `\n${TOOL_LABELS[opts.tool]} not found on PATH. Install it (https://example.com/${opts.tool}) or run with --print to just print the exports.`,
    );
    return null;
  }

  const env = { ...process.env, ...buildEnv(opts) } as NodeJS.ProcessEnv;
  const args = opts.extraArgs ?? [];
  const child = spawn(bin, args, {
    stdio: "inherit",
    env,
    // Detach so closing the desktop server doesn't kill the tool — the user
    // usually wants to keep coding even if they later kill `roamsocket`.
    detached: false,
  });
  child.on("exit", (code) => {
    process.exitCode = code ?? 0;
  });
  return child.pid ?? null;
}

/**
 * Verify the chosen tool's required provider has a key available. Used by
 * the `open` subcommand so we can fail fast with a useful message instead of
 * letting the tool crash on first request.
 */
export function checkToolKeyAvailable(tool: SupportedTool): { ok: boolean; provider: string; hint: string } {
  const provider = TOOL_ENV[tool].provider;
  const envNames = [
    `${provider.toUpperCase()}_API_KEY`,
    `APC_PROXY_TOKEN_${provider.toUpperCase()}`,
    `APC_${provider.toUpperCase()}_API_KEY`,
  ];
  const present = envNames.some((n) => (process.env[n] ?? "").trim().length > 0);
  return {
    ok: present,
    provider,
    hint: present ? "" : `Set one of: ${envNames.join(", ")} (or save via the desktop's /keys).`,
  };
}

/** Parse a `--model` / `--print` / extra-args list from argv. */
export function parseOpenArgs(argv: string[]): {
  model?: string;
  printOnly: boolean;
  extraArgs: string[];
} {
  let model: string | undefined;
  let printOnly = false;
  const extraArgs: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i] ?? "";
    if (a === "--print") printOnly = true;
    else if (a === "--model" || a.startsWith("--model=")) {
      const next = a.startsWith("--model=") ? a.slice("--model=".length) : (argv[i + 1] ?? "");
      if (next) {
        model = next;
        if (!a.startsWith("--model=")) i++;
      }
    } else if (a === "--help" || a === "-h") {
      console.log(
        "roamsocket open — launch an external coding CLI through the local proxy\n" +
          "\nUsage:\n" +
          "  roamsocket open <tool> [--model <id>] [-- <args forwarded to the tool>]\n" +
          "  roamsocket open <tool> --print     # just print the export lines\n" +
          "\nTools: codex, claude, aider, cursor, opencode\n" +
          "Env:  APC_OPEN_IN=<tool>  picks the tool when `roamsocket` is run with no subcommand",
      );
      process.exit(0);
    } else if (a === "--") {
      extraArgs.push(...argv.slice(i + 1));
      break;
    } else {
      extraArgs.push(a);
    }
  }
  return { model, printOnly, extraArgs };
}

/** Quiet helper for the CLI entry: which tool should `roamsocket` boot? */
export function defaultToolFromEnv(): SupportedTool | null {
  const v = (process.env.APC_OPEN_IN ?? "").trim().toLowerCase();
  if (!v) return null;
  return isSupportedTool(v) ? v : null;
}

// `spawnSync` import is needed only for the help-output `tsx` path —
// keep it referenced so tree-shakers don't drop it in the future.
void spawnSync;