# desktop-server

Node + TypeScript companion server for the anyprov-code iOS app. It pairs with
the app over a WebSocket, clones a GitHub repo, drives the agent loop against a
provider, executes tools, and opens a pull request.

The same package also ships as an **Electron desktop app**: a native window
that hosts a built-in client UI mirroring the iOS shell (settings for
provider keys and GitHub, repo picker, composer with streaming tool/diff
output, history), plus a system tray so closing the window keeps the server
running in the background.

## Run

### Headless server (CLI)

```bash
npm install
npm run dev          # watch mode (tsx)
npm start            # from a prior `npm run build`
```

On start it prints a **pairing code** and a QR payload. Enter the address
(`http://<your-ip>:4319`) and code in the app's *Pair with a server* screen.

### Electron app (GUI)

```bash
npm run electron:dev     # hot-reload dev (Vite + Electron Forge)
npm run electron:package # build a packaged app for the current platform
npm run make             # build distributable installers (.dmg/.exe/.zip)
```

The Electron shell runs the same HTTP + WebSocket server in-process and opens
a single window. Closing the window hides the app to the macOS menu bar /
Windows task tray by default. The first close asks whether you want the app
to fully quit on future closes; the answer is remembered.

To really quit: tray menu → *Quit AnyProv Code*, or `Cmd-Q` on macOS.

### Environment

| Var | Default | Purpose |
|-----|---------|---------|
| `PORT` | `4319` | HTTP + WebSocket port |
| `APC_NAME` | `anyprov-code desktop` | shown when pairing |
| `APC_MOCK` | unset | `1` runs a deterministic offline agent (no API key) |

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
  renderer/
    index.html          Sidebar shell (Home / History / Settings).
    styles.css          Dark, native-feeling theme.
    main.ts             Hash-routed SPA: composer, streaming session,
                        history list, settings (provider keys + GitHub).
scripts/smoke.ts        offline end-to-end test
forge.config.ts         Electron Forge + Vite plugin config
vite.{main,preload,renderer}.config.ts   per-target Vite configs
```

See [`../docs/protocol.md`](../docs/protocol.md) for the wire format.

## Packaging notes

The project is `"type": "module"` so the headless server can use ESM imports.
The Electron main + preload bundles are emitted as CommonJS with a `.cjs`
extension so Node loads them under the same project root.
