/**
 * RoamSocket CLI entry.
 *
 *   roamsocket                       # headless companion + OpenAI/Anthropic proxy (default)
 *   roamsocket --tui                 # legacy Ink coding agent UI (still supported)
 *   roamsocket open <tool>           # print exports + launch Codex/Claude/Aider/Cursor/OpenCode
 *   roamsocket --serve-only          # alias for the default (server + proxy, no UI)
 *   APC_MOCK=1 roamsocket            # offline mock agent (TUI only)
 *
 * The default flipped to headless so external coding CLIs can use the
 * desktop's stored keys via the local proxy on the same port. The TUI is
 * still reachable via `--tui` for users who want the in-process agent loop.
 */
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import React from 'react';
import { render } from 'ink';
import { startServer, type RunningServer } from '../index.js';
import { currentAccessTunnel } from '../workspace/access-tunnel.js';
import type { ServerMessage } from '../protocol.js';
import { LocalCliSession } from './local-session.js';
import {
  defaultPermissionMode,
  hasAnyKey,
  loadCliSecrets,
  resolveModelSelection,
  updateCliSecrets,
} from './secrets.js';
import {
  App,
  createMessageBus,
  createPermissionBridge,
} from './tui/App.js';
import {
  defaultToolFromEnv,
  isSupportedTool,
  launchTool,
} from './open/index.js';

export interface CliMainOptions {
  argv?: string[];
  /** Force serve-only (tests). */
  forceServeOnly?: boolean;
  /** Skip TUI even on TTY (tests). */
  forceNoTui?: boolean;
  /** Force TUI on (overrides the headless default). */
  forceTui?: boolean;
}

function printHelp(): void {
  console.log(`RoamSocket — desktop companion + OpenAI/Anthropic proxy for external coding CLIs

Usage:
  roamsocket                         Headless server + proxy (default; iOS app can pair)
  roamsocket --tui                   Launch the legacy Ink coding agent UI in this terminal
  roamsocket open <tool>             Print exports + launch an external coding CLI
                                       (codex, claude, aider, cursor, opencode)
  roamsocket --serve-only            Headless server only (no TUI, no auto-launch)

Options:
  --serve-only       Headless server only (no agent TUI)
  --tui              Force the legacy Ink agent UI
  --cwd <path>       Working directory for the local agent (default: .)
  --provider <id>    Provider (anthropic, openai, groq, …)
  --model <id>       Model id
  --mock             Offline mock agent (same as APC_MOCK=1)
  --no-launch        Don't auto-launch a tool even if APC_OPEN_IN is set
  --help, -h         Show this help

Environment:
  PORT                 Listen port (default 4319)
  APC_MOCK=1           Mock agent
  APC_HOST             Bind address
  APC_OPEN_IN=<tool>   Auto-launch this tool after the server is up
                         (codex | claude | aider | cursor | opencode)
  APC_PROXY_TOKEN=<…>  Static bearer for /v1/* (else a random token is minted)
  APC_PROXY_PROVIDER   Default upstream when X-RoamSocket-Provider isn't sent
  ANTHROPIC_API_KEY / OPENAI_API_KEY / …   Provider keys

The default is headless so external coding CLIs can use the desktop's keys
through http://localhost:4319/v1. The iOS app pairs the same way as before.
The Ink TUI is reachable via --tui for users who want the in-process agent.
`);
}

function parseArgs(argv: string[]) {
  let serveOnly = false;
  let tui = false;
  let noLaunch = false;
  let cwd = process.cwd();
  let provider: string | undefined;
  let model: string | undefined;
  let mock = process.env.APC_MOCK === '1';
  let help = false;
  let openTool: string | undefined;
  const openArgs: string[] = [];

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === '--serve-only') serveOnly = true;
    else if (a === '--tui') tui = true;
    else if (a === '--no-launch') noLaunch = true;
    else if (a === '--mock') mock = true;
    else if (a === '--help' || a === '-h') help = true;
    else if (a === '--cwd') {
      cwd = path.resolve(argv[++i] ?? cwd);
    } else if (a.startsWith('--cwd=')) {
      cwd = path.resolve(a.slice('--cwd='.length));
    } else if (a === '--provider') {
      provider = argv[++i];
    } else if (a.startsWith('--provider=')) {
      provider = a.slice('--provider='.length);
    } else if (a === '--model') {
      model = argv[++i];
    } else if (a.startsWith('--model=')) {
      model = a.slice('--model='.length);
    } else if (a === 'open') {
      openTool = argv[++i];
      // Everything after the tool name is forwarded to it.
      openArgs.push(...argv.slice(i + 1));
      break;
    }
  }

  return { serveOnly, tui, noLaunch, cwd, provider, model, mock, help, openTool, openArgs };
}

/**
 * Programmatic one-shot agent turn (verification / scripts).
 * No server; runs LocalCliSession with mock or real keys.
 */
export async function runOneShot(opts: {
  text: string;
  workdir: string;
  mock?: boolean;
  permissionMode?: 'acceptEdits' | 'ask' | 'plan';
  onMessage?: (msg: ServerMessage) => void;
}): Promise<{ messages: ServerMessage[]; ok: boolean }> {
  const messages: ServerMessage[] = [];
  const mock = opts.mock ?? process.env.APC_MOCK === '1';
  const model = resolveModelSelection({ mock });
  const session = await LocalCliSession.create({
    workdir: opts.workdir,
    model,
    permissionMode: opts.permissionMode ?? 'acceptEdits',
    mock,
    onMessage: (msg) => {
      messages.push(msg);
      opts.onMessage?.(msg);
    },
    onPermission: async () => 'allow',
  });
  await session.send(opts.text);
  const hasAssistant = messages.some((m) => m.type === 'assistant_delta' || m.type === 'tool_call');
  return { messages, ok: hasAssistant };
}

export async function main(opts: CliMainOptions = {}): Promise<void> {
  const argv = opts.argv ?? process.argv.slice(2);
  const args = parseArgs(argv);

  if (args.help) {
    printHelp();
    return;
  }

  // `roamsocket open <tool>` is its own flow — start the server, print the
  // exports, spawn the tool. Doesn't touch the TUI or model selection.
  if (args.openTool !== undefined) {
    if (!isSupportedTool(args.openTool)) {
      console.error(
        `Unknown tool "${args.openTool}". Supported: codex, claude, aider, cursor, opencode.`,
      );
      process.exitCode = 2;
      return;
    }
    let server: RunningServer;
    try {
      server = await startServer({
        silent: false,
        cliSettings: false,
        mock: args.mock,
      });
    } catch (err) {
      console.error("Failed to start server:", err);
      process.exitCode = 1;
      return;
    }
    const printOnly = args.openArgs.includes("--print");
    const pid = launchTool({
      tool: args.openTool,
      baseUrl: server.proxyBaseUrl,
      bearer: server.proxyToken,
      ...(args.model ? { model: args.model } : {}),
      printOnly,
      extraArgs: args.openArgs.filter((a) => a !== "--print"),
    });
    // --print: the user just wants the env lines; close the server and exit.
    if (printOnly) {
      await server.close();
      return;
    }
    // Spawned a real tool — forward signals so it dies when the user hits ^C.
    if (pid !== null) {
      const child = { pid };
      const stop = async () => {
        try {
          process.kill(child.pid, "SIGTERM");
        } catch {
          /* already gone */
        }
        await server.close();
      };
      process.on("SIGINT", () => void stop().then(() => process.exit(0)));
      process.on("SIGTERM", () => void stop().then(() => process.exit(0)));
    }
    return;
  }

  if (args.mock) {
    process.env.APC_MOCK = '1';
  }

  const isTty = Boolean(process.stdin.isTTY && process.stdout.isTTY);
  // Default: headless server + proxy. The TUI is opt-in via --tui. We keep
  // the legacy `APC_TUI=auto` knob so muscle-memory workflows survive.
  const legacyAutoTui = process.env.APC_TUI === 'auto';
  const wantsTui =
    opts.forceTui === true ||
    args.tui ||
    (legacyAutoTui && isTty);
  const serveOnly =
    opts.forceServeOnly ||
    args.serveOnly ||
    (!wantsTui && !opts.forceTui);

  if (serveOnly) {
    await startServer({
      silent: false,
      cliSettings: isTty && process.env.APC_CLI_SETTINGS !== '0',
      mock: args.mock,
    });
    // If APC_OPEN_IN is set we just remind the user to run `roamsocket open
    // <tool>` — keeping the auto-launch on the dedicated subcommand keeps the
    // default command easy to reason about (no surprise child process).
    if (!args.noLaunch) {
      const tool = defaultToolFromEnv();
      if (tool) {
        console.log(`\n[apc] APC_OPEN_IN=${tool} set — run \`roamsocket open ${tool}\` to launch it.`);
      }
    }
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
    console.error('Failed to start server:', err);
    process.exitCode = 1;
    return;
  }

  const secrets = loadCliSecrets();
  const mock = args.mock || process.env.APC_MOCK === '1';
  const model = resolveModelSelection({
    provider: args.provider,
    model: args.model,
    mock,
    secrets,
  });
  const permissionMode = defaultPermissionMode(secrets);

  if (!mock && !hasAnyKey(secrets) && !model.apiKey) {
    console.error(
      'No API key found. Set ANTHROPIC_API_KEY (or another provider key),\n' +
        'use /keys in the TUI, or run with --mock / APC_MOCK=1.'
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
    { alternateScreen: true }
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
