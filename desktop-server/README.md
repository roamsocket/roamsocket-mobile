# desktop-server

Node + TypeScript companion server for the code-mobile-ai iOS app. It pairs with
the app over a WebSocket, clones a GitHub repo, drives the agent loop against a
provider, executes tools, and opens a pull request.

## Run

```bash
npm install
npm run dev          # watch mode (tsx)
npm start            # from a prior `npm run build`
```

On start it prints a **pairing code** and a QR payload. Enter the address
(`http://<your-ip>:4319`) and code in the app's *Pair with a server* screen.

### Environment

| Var | Default | Purpose |
|-----|---------|---------|
| `PORT` | `4319` | HTTP + WebSocket port |
| `CMAI_NAME` | `code-mobile-ai desktop` | shown when pairing |
| `CMAI_MOCK` | unset | `1` runs a deterministic offline agent (no API key) |

## Verify

```bash
npm run typecheck
npm run build
npm run smoke        # full pair → session → tool → diff → PR, all offline
```

The smoke test creates a throwaway local git repo, starts the server with the
mock agent, and asserts the whole protocol flow end-to-end.

## Layout

```
src/
  index.ts        HTTP (/health, /pair) + WebSocket (/session) bootstrap
  pairing.ts      pairing code → bearer token
  protocol.ts     zod message schemas (canonical; mirrored in Swift)
  sessions.ts     per-session workdir, agent, permissions, PR creation
  agent/loop.ts   the agentic tool-use loop
  providers/      anthropic (streaming) + openai-compatible + mock
  tools/          bash, read_file, write_file, edit_file, glob
  git/github.ts   clone / branch / commit / push / diff
scripts/smoke.ts  offline end-to-end test
```

See [`../docs/protocol.md`](../docs/protocol.md) for the wire format.
