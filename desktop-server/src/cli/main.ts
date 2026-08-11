/**
 * RoamSocket CLI entry: companion server + coding agent TUI (default on TTY).
 *
 *   roamsocket                 # server + Ink agent UI
 *   roamsocket --serve-only    # headless server (legacy)
 *   APC_MOCK=1 roamsocket      # offline mock agent
 */
import path from "node:path";
import { pathToFileURL } from "node:url";
import React from "react";
import { render } from "ink";
import { startServer, type RunningServer } from "../index.js";
import { currentAccessTunnel } from "../workspace/access-tunnel.js";
import type { ServerMessage } from "../protocol.js";
import { LocalCliSession } from "./local-session.js";
import {
  defaultPermissionMode,
  hasAnyKey,
  loadCliSecrets,
  resolveModelSelection,
  updateCliSecrets,
} from "./secrets.js";
import {
  App,
  createMessageBus,
  createPermissionBridge,
} from "./tui/App.js";

export interface CliMainOptions {
  argv?: string[];
  /** Force serve-only (tests). */
  forceServeOnly?: boolean;
  /** Skip TUI even on TTY (tests). */
  forceNoTui?: boolean;
}

function printHelp(): void {
  console.log(`RoamSocket — coding agent CLI + desktop companion server

Usage:
  roamsocket [options]

Options:
  --serve-only       Headless server only (no agent TUI)
  --cwd <path>       Working directory for the local agent (default: .)
  --provider <id>    Provider (anthropic, openai, groq, …)
  --model <id>       Model id
  --mock             Offline mock agent (same as APC_MOCK=1)
  --help, -h         Show this help

Environment:
  PORT               Listen port (default 4319)
  APC_MOCK=1         Mock agent
  APC_HOST           Bind address
  ANTHROPIC_API_KEY / OPENAI_API_KEY / …   Provider keys

On a TTY, starts the pairing server and opens the coding agent UI.
The iOS app can still pair with the same process. Sessions are independent
(terminal works in cwd; phone clones GitHub repos).

Slash commands (type / for completions): /help /mobile /pair /goal /model
  /metal /permission /keys /effort /context /doctor /init /memory /diff /review /quit
`);
}

function parseArgs(argv: string[]) {
  let serveOnly = false;
  let cwd = process.cwd();
  let provider: string | undefined;
  let model: string | undefined;
  let mock = process.env.APC_MOCK === "1";
  let help = false;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "--serve-only") serveOnly = true;
    else if (a === "--mock") mock = true;
    else if (a === "--help" || a === "-h") help = true;
    else if (a === "--cwd") {
      cwd = path.resolve(argv[++i] ?? cwd);
    } else if (a.startsWith("--cwd=")) {
      cwd = path.resolve(a.slice("--cwd=".length));
    } else if (a === "--provider") {
      provider = argv[++i];
    } else if (a.startsWith("--provider=")) {
      provider = a.slice("--provider=".length);
    } else if (a === "--model") {
      model = argv[++i];
    } else if (a.startsWith("--model=")) {
      model = a.slice("--model=".length);
    }
  }

  return { serveOnly, cwd, provider, model, mock, help };
}

/**
 * Programmatic one-shot agent turn (verification / scripts).
 * No server; runs LocalCliSession with mock or real keys.
 */
export async function runOneShot(opts: {
  text: string;
  workdir: string;
  mock?: boolean;
  permissionMode?: "acceptEdits" | "ask" | "plan";
  onMessage?: (msg: ServerMessage) => void;
}): Promise<{ messages: ServerMessage[]; ok: boolean }> {
  const messages: ServerMessage[] = [];
  const mock = opts.mock ?? process.env.APC_MOCK === "1";
  const model = resolveModelSelection({ mock });
  const session = await LocalCliSession.create({
    workdir: opts.workdir,
    model,
    permissionMode: opts.permissionMode ?? "acceptEdits",
    mock,
    onMessage: (msg) => {
      messages.push(msg);
      opts.onMessage?.(msg);
    },
    onPermission: async () => "allow",
  });
  await session.send(opts.text);
  const hasAssistant = messages.some(
    (m) => m.type === "assistant_delta" || m.type === "tool_call",
  );
  return { messages, ok: hasAssistant };
}

export async function main(opts: CliMainOptions = {}): Promise<void> {
  const argv = opts.argv ?? process.argv.slice(2);
  const args = parseArgs(argv);

  if (args.help) {
    printHelp();
    return;
  }

  if (args.mock) {
    process.env.APC_MOCK = "1";
  }

  if (args.provider || args.model) {
    updateCliSecrets({
      ...(args.provider ? { provider: args.provider } : {}),
      ...(args.model ? { model: args.model } : {}),
    });
  }

  const isTty = Boolean(process.stdin.isTTY && process.stdout.isTTY);
  const serveOnly =
    opts.forceServeOnly || args.serveOnly || opts.forceNoTui || !isTty;

  if (serveOnly) {
    await startServer({
      silent: false,
      cliSettings: isTty && process.env.APC_CLI_SETTINGS !== "0",
      mock: args.mock,
    });
    return;
  }

  let server: RunningServer;
  try {
    server = await startServer({
      silent: true,
      cliSettings: false,
      mock: args.mock,
    });
  } catch (err) {
    console.error("Failed to start server:", err);
    process.exitCode = 1;
    return;
  }

  const secrets = loadCliSecrets();
  const mock = args.mock || process.env.APC_MOCK === "1";
  const model = resolveModelSelection({
    provider: args.provider,
    model: args.model,
    mock,
    secrets,
  });
  const permissionMode = defaultPermissionMode(secrets);

  if (!mock && !hasAnyKey(secrets) && !model.apiKey) {
    console.error(
      "No API key found. Set ANTHROPIC_API_KEY (or another provider key),\n" +
        "use /keys in the TUI, or run with --mock / APC_MOCK=1.",
    );
  }

  const bus = createMessageBus();
  const permBridge = createPermissionBridge();

  const session = await LocalCliSession.create({
    workdir: args.cwd,
    model,
    permissionMode,
    mock,
    onMessage: (msg) => bus.emit(msg),
    onPermission: (req) => permBridge.onPermission(req),
  });

  const serverStatus = {
    port: server.port,
    host: server.host,
    pairingCode: server.pairingCode,
    getPairingCode: () => server.pairingCode,
    getTunnelUrl: () => currentAccessTunnel()?.url ?? null,
  };

  // alternateScreen: dedicated full terminal buffer (like vim/htop) so a
  // height=rows frame cannot scroll the primary buffer and clip the header.
  const ink = render(
    React.createElement(App, {
      session,
      server: serverStatus,
      mock,
      bus,
      permBridge,
      onQuit: async () => {
        session.interrupt();
        ink.unmount();
        await server.close();
      },
    }),
    { alternateScreen: true },
  );

  await ink.waitUntilExit();
}

/**
 * Auto-run only when this module is the process entrypoint
 * (`tsx src/cli/main.ts` / `node dist/src/cli/main.js`).
 * Do NOT match bin/roamsocket.js — that file imports `main` and calls it once.
 */
function isDirectMain(): boolean {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return import.meta.url === pathToFileURL(path.resolve(entry)).href;
  } catch {
    return false;
  }
}

if (isDirectMain()) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
