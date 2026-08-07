# desktop-server

Node + TypeScript companion server for the **RoamSocket** iOS app. It pairs with
the app over a WebSocket, clones a GitHub repo, drives the agent loop against a
provider, executes tools, and opens a pull request.

The same package also ships as an **Electron desktop app**: a native window
that hosts a built-in client UI mirroring the iOS shell (settings for
provider keys and GitHub, repo picker, composer with streaming tool/diff
output, history), plus a system tray so closing the window keeps the server
running in the background.

## Install (global CLI)

```bash
npm install -g roamsocket
roamsocket
```

Legacy CLI aliases (install continuity only, same entrypoint): `codesocket`,
`codesocket-server`, `anyprov-code-server`. Prefer `roamsocket`.

Requires **Node.js 20+**. The first install may compile native deps (`node-pty`);
you need a working C/C++ toolchain (Xcode CLT on macOS, build-essential on Linux).

Env vars below still apply. Default port is **4319**.

## Run (from this repo)

### Headless server (CLI)

```bash
npm install
npm run dev          # watch mode (tsx)
npm start            # from a prior `npm run build`
# or: node bin/roamsocket.js
```

On start it prints a **large pairing code** and an **ASCII QR** (JSON payload
`{"host","code"}`). Scan it in the iOS app under *Pair server → Scan desktop QR*,
or type the 6-digit code after picking a nearby server.

When a public tunnel comes up (auto-tunnel after pair, or always-on remote
access), the terminal prints the **tunnel URL** and re-prints the QR so
`host` is the HTTPS tunnel address instead of the LAN URL.

Headless TTY sessions also open a **CLI settings** prompt (`settings>`) for
LAN discovery, auto-tunnel, and code display. Type `h` for help, `q` to leave
the menu (server keeps running).

### Electron app (GUI)

```bash
npm run electron:dev     # hot-reload dev (Vite + Electron Forge)
npm run electron:package # build a packaged app for the current platform
npm run make             # build distributable installers (.dmg/.exe/.zip)
```

The Electron shell runs the same HTTP + WebSocket server in-process and opens
a full desktop **client** (sidebar: Chats, Projects, Artifacts, Code, Settings —
no Vision) with BYOK chat streaming, on-device Metal models on macOS (chat only),
and coding sessions against the local agent. Closing the window hides the app
to the macOS menu bar / Windows task tray by default. The first close asks
whether you want the app to fully quit on future closes; the answer is remembered.

To really quit: tray menu → *Quit RoamSocket*, or `Cmd-Q` on macOS.

### Environment

| Var | Default | Purpose |
|-----|---------|---------|
| `PORT` | `4319` | HTTP + WebSocket port |
| `APC_HOST` | `0.0.0.0` | bind address (`0.0.0.0` = LAN-reachable) |
| `APC_NAME` | `RoamSocket desktop` | shown when pairing / Bonjour |
| `APC_ADVERTISE` | on | set `0` to disable Bonjour/mDNS LAN broadcast |
| `APC_AUTO_TUNNEL` | on | set `0` to disable auto public tunnel after phone pair |
| `APC_CLI_SETTINGS` | on (TTY) | set `0` to skip the interactive settings prompt |
| `APC_MOCK` | unset | `1` runs a deterministic offline agent (no API key) |

Shared connection prefs live under `~/.roamsocket/` (or legacy `~/.codesocket/` / `~/.anyprov-code/` if already present) as `desktop-prefs.json` (Electron
settings UI and the CLI menu edit the same file).

## Verify

```bash
npm run typecheck           # both server and electron tsconfigs
npm run typecheck:server    # headless server only
npm run typecheck:electron  # main/preload/renderer only
npm run build               # tsc to dist/
npm run smoke               # full pair → session → tool → diff → PR, all offline
```

The smoke test creates a throwaway local git repo, starts the server with the
mock agent, and asserts the whole protocol flow end-to-end.

## Layout

```
src/
  index.ts              HTTP (/health, /pair) + WebSocket (/session) bootstrap
                        Exports `startServer()` reused by Electron main.
  pairing.ts            pairing code → bearer token
  protocol.ts           zod message schemas (canonical; mirrored in Swift)
  sessions.ts           per-session workdir, agent, permissions, PR creation
  agent/loop.ts         the agentic tool-use loop
  providers/            anthropic (streaming) + openai-compatible + mock
  tools/                bash, read_file, write_file, edit_file, glob
  git/github.ts         clone / branch / commit / push / diff
  electron/
    main.ts             Electron main process: window, tray, close-to-tray,
                        IPC, safeStorage-backed secret persistence.
    preload.ts          contextBridge surface for the renderer.
  client/               Pure UI helpers (greeting, history, projects, artifacts, theme)
  metal/                On-device MLX catalog, download store, mlx-lm runtime (chat only)
  renderer/
    index.html          Full client shell (Chats / Projects / Artifacts / Code / Settings).
    styles.css          Cool blue-grey theme shared with iOS.
    main.ts             Hash-routed SPA: chat, code sessions, projects, artifacts, settings.
    chat-stream.ts      BYOK provider streaming for chat mode.
scripts/smoke.ts        offline end-to-end protocol test
scripts/client-unit.ts  pure client module tests
scripts/metal-check.ts  Metal catalog + runtime error-path checks
forge.config.ts         Electron Forge + Vite plugin config
vite.{main,preload,renderer}.config.ts   per-target Vite configs
```

See [`../docs/protocol.md`](../docs/protocol.md) for the wire format.

## Packaging notes

The project is `"type": "module"` so the headless server can use ESM imports.
The Electron main + preload bundles are emitted as CommonJS with a `.cjs`
extension so Node loads them under the same project root.
