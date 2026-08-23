# Wire protocol

The iOS and Android apps and the desktop server speak a small JSON protocol.
Pairing is over HTTP; the coding session runs over a WebSocket. The canonical
definitions live in `desktop-server/src/protocol.ts` (zod) and are mirrored by
the Swift Codable types in `ios/AnyProvCore/Sources/AnyProvCore/Server/Protocol.swift`
and the kotlinx.serialization types in `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/protocol/`.
Keep all four in sync.

## Local discovery (Bonjour / mDNS)

The desktop companion advertises itself on the LAN so phones can list nearby
servers without typing an IP:

| | |
|--|--|
| Service type | `_roamsocket._tcp` |
| Port | HTTP listen port (default `4319`) |
| TXT | `name` (server display name), `version`, `path` (`/`) |

The pairing code is **not** published — the app still needs the 6-digit code
from the desktop UI / console. Disable advertising with `APC_ADVERTISE=0`.
Default listen address is `0.0.0.0` (all interfaces); override with `APC_HOST`.

## Auto tunnel (stable off-LAN URL)

After a successful `/pair` (or when a session WebSocket connects), the desktop
starts a public reverse tunnel to its own listen port (Cloudflare quick tunnel
preferred, then ngrok, then localtunnel via npx). It then pushes:

```json
{ "type": "remote_endpoint", "status": "up", "url": "https://….trycloudflare.com", "provider": "cloudflare" }
```

The iOS app updates its saved base URL to that HTTPS origin while **keeping
the same bearer token**, so coding keeps working after leaving home Wi‑Fi.
Disable with `APC_AUTO_TUNNEL=0`.

If the phone later cannot reach that public URL, Smart mode falls back to the
saved LAN address, **drops the dead tunnel URL**, and sends
`remote_endpoint_request` with `force: true` so the desktop kills the old
tunnel process and opens a fresh one. The new URL is applied only after a
successful health check.

## HTTP

### `GET /health`
```json
{ "ok": true, "name": "RoamSocket desktop", "version": "0.1.0", "publicUrl": "https://…", "tunnelStatus": "up" }
```

### `POST /pair`
Request:
```json
{ "code": "123456", "deviceName": "Julian's iPhone" }
```
Response `200`:
```json
{ "token": "…", "serverName": "RoamSocket desktop", "serverVersion": "0.1.0", "publicUrl": "https://…?" }
```
`publicUrl` is set only if a tunnel is already up. `401` on a wrong code. The
`token` is a bearer token used to open the WebSocket.

### `GET /metal/models`
Lists **desktop-installed** Metal / MLX models the coding agent can use. Auth
required (`Authorization: Bearer <token>` from pairing, or `?token=`).

Response `200`:
```json
{
  "provider": "localMetal",
  "runtimeReady": true,
  "supported": true,
  "detail": "…",
  "models": [
    { "hubID": "mlx-community/…", "displayName": "Llama …", "downloadedAt": 1710000000000 }
  ]
}
```

The phone coding model picker shows these models (not phone-local Metal
weights, which may not match the desktop store). Provider wire values
`localMetal` and `local-metal` both mean desktop Metal.

## Provider proxy (`/v1/*`)

The desktop also exposes an **OpenAI- and Anthropic-compatible pass-through
proxy** on the same port. External coding CLIs (Codex, Claude Code, Aider,
Cursor CLI, OpenCode, …) point their base URL at
`http://localhost:4319/v1` and reuse the desktop's stored provider keys —
no per-tool setup, no re-implementation of the wire formats.

The proxy is a thin pass-through: it authenticates the request, looks up
the user's API key, then forwards the request (and streams the response)
to the real provider. Nothing is re-serialized, so tool calls, SSE
streaming, and the latest model features work as-is.

### Auth

| Token source | Use |
|---|---|
| Pairing bearer (from `/pair`) | Same token the iOS app uses for `/session`. |
| `APC_PROXY_TOKEN` env var | Static bearer you pin for external tools. |
| Random per-process token | Default. The banner prints it on every start. |

Pass it as `Authorization: Bearer <token>` or `X-Api-Key: <token>`.

### Provider selection

The proxy needs to know which upstream to forward to:

- **`X-RoamSocket-Provider: <id>` request header** (preferred — one URL covers all providers).
- **Auto-detection** for `/v1/messages` (Anthropic).
- **`APC_PROXY_PROVIDER` env var** as a fallback.

Recognized provider ids: `openai`, `anthropic`, `groq`, `openrouter`,
`xai`, `mistral`, `minimax`.

### API key lookup

For the resolved provider, the proxy looks up an API key in this order:
1. `<PROVIDER>_API_KEY` env var
2. `APC_PROXY_TOKEN_<PROVIDER>` env var
3. `secrets.json` in the desktop data dir (written by the legacy `roamsocket --tui` `/keys` command)

### Routes

| Method | Path                  | Forwards to                          |
|--------|-----------------------|--------------------------------------|
| `GET`  | `/v1/models`          | Synthesized OpenAI-shaped list       |
| `POST` | `/v1/chat/completions`| OpenAI-compatible completion         |
| `POST` | `/v1/completions`     | Legacy OpenAI completions            |
| `POST` | `/v1/messages`        | Anthropic-compatible messages        |
| `*`    | `/v1/<anything>`      | Catch-all (audio / images / etc.)    |

### CLI shortcuts

```bash
# Print the env exports (no tool launched):
roamsocket open codex --print

# Launch the tool with the right env already set:
roamsocket open claude
roamsocket open aider
roamsocket open cursor
roamsocket open opencode

# Set a stable token across restarts:
export APC_PROXY_TOKEN=my-shared-secret
```

Each tool's env vars are set according to its own conventions (e.g. Codex
reads `OPENAI_BASE_URL` + `OPENAI_API_KEY`; Claude Code reads
`ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`). The `X_Roamsocket_Provider`
hint is also set so the proxy knows which upstream to forward to.

## WebSocket `GET /session?token=…`

Every frame is a JSON object with a `type` discriminator.

### App → server

| type                  | fields |
|-----------------------|--------|
| `create_session`      | `sessionId?`, `repo{fullName, baseBranch?, workBranch, githubToken?}`, `environment?`, `model{provider, model, effort, apiKey, baseUrl?, apiStyle?}`, `permissionMode`, `skills?` (string[]), `mcpServers?` (`MCPServer[]`: `id`, `name`, `description`, `command`, `args`, `env`, `isEnabled`) |
| `user_message`        | `sessionId`, `text`, `model?` (optional full `ModelSelection` — rebinds the agent for this turn) |
| `permission_response` | `sessionId`, `requestId`, `decision` (`allow`\|`deny`) |
| `interrupt`           | `sessionId` |
| `create_pr`           | `sessionId`, `title`, `body` |
| `git_publish`         | `sessionId`, `message`, `commit`, `push`, `openPr` |
| `terminal_open`       | `sessionId`, `terminalId?`, `cols?`, `rows?` |
| `terminal_input`      | `terminalId`, `data` |
| `terminal_kill`       | `terminalId` |
| `file_list`           | `sessionId`, `path` |
| `file_read`           | `sessionId`, `path` |
| `file_write`          | `sessionId`, `path`, `content` |
| `port_list`           | `sessionId` |
| `tunnel_start`        | `sessionId`, `port`, `provider` (`auto`\|`ngrok`\|`cloudflare`\|`localtunnel`\|`bore`) |
| `tunnel_stop`         | `sessionId`, `tunnelId` |
| `tunnel_list`         | `sessionId` |
| `remote_endpoint_request` | `force?` (bool) — re-publish the coding-server public tunnel; `force: true` tears down the current access tunnel and starts a new one |

`permissionMode` is one of `acceptEdits`, `plan`, `ask` (the composer's
permission pill). `provider` is one of `anthropic`, `openai`, `google`, `groq`,
`openrouter`, `xai`, `mistral`, `minimax`, `localMetal` / `local-metal`
(desktop Metal), or a custom id `custom:<slug>`.

`model` may also include optional fields for user-defined endpoints:

| field | meaning |
|-------|---------|
| `baseUrl` | e.g. `http://localhost:11434/v1` — host the agent should call |
| `apiStyle` | `openai` (Chat Completions) or `anthropic` (Messages API) |

When `baseUrl` is set (or `provider` is `custom:…`), the desktop agent must not
fall back to the built-in OpenAI / Anthropic cloud hosts.

### Server → app

| type                 | fields |
|----------------------|--------|
| `session_created`    | `sessionId`, `workdir`, `baseBranch`, `workBranch` |
| `assistant_delta`    | `sessionId`, `text` (streamed assistant text / tool stdout) |
| `tool_call`          | `sessionId`, `callId`, `tool`, `summary`, `input` |
| `tool_result`        | `sessionId`, `callId`, `ok`, `output` |
| `task_list`          | `sessionId`, `tasks[]` (`id`, `content`, `status`) — agent checklist snapshot |
| `goal_status`        | `sessionId`, `status` (`active`\|`achieved`\|`cleared`\|`none`), `condition?`, `reason?`, `turnsEvaluated?`, `startedAt?`, `elapsedMs?`, `message` — `/goal` slash-command state |
| `model_status`       | `sessionId`, `status` (`loading`\|`generating`\|`done`), `hubID?`, `message?` — desktop Metal/MLX model load progress |
| `diff`               | `sessionId`, `path`, `patch`, `added`, `removed` |
| `permission_request` | `sessionId`, `requestId`, `tool`, `summary` |
| `session_done`       | `sessionId`, `stopReason?` |
| `transcript_replay`  | `sessionId`, `events` (`TranscriptEvent[]`), `truncated` (bool), `isLive` (bool) — emitted on WebSocket reattach to backfill the phone with what happened while its socket was down; live events then continue on the same connection |
| `pr_created`         | `sessionId`, `url` |
| `git_result`         | `sessionId`, `action`, `ok`, `detail`, `url?` |
| `file_list_result`   | `sessionId`, `path`, `entries[]`, `diff?`, `changes?` |
| `file_read_result`   | `sessionId`, `path`, `content`, `truncated`, `diff?` |
| `file_write_result`  | `sessionId`, `path`, `ok`, `message?` |
| `port_list_result`   | `sessionId`, `ports[]` |
| `tunnel_status`      | `sessionId`, `tunnels[]`, `availableProviders[]` |
| `terminal_data`      | `terminalId`, `stream`, `data` |
| `terminal_control`   | `terminalId`, `event`, `code` |
| `error`              | `sessionId?`, `message` |

`git_publish` runs the selected steps in order: optional commit (using
`message`), optional push, optional open-PR (returns a GitHub compare URL).
`create_pr` is still supported and is equivalent to commit + push + open PR
with `title` as the commit message.

`tunnel_start` exposes a local listening port through a public HTTPS URL using
ngrok, Cloudflare quick tunnels, localtunnel (npx), or bore. `provider: "auto"`
picks the best installed CLI.

## Typical flow

```
app  → POST /pair {code}              → {token}
app  → ws /session?token=…
app  → create_session {repo, model, permissionMode}
srv  → session_created {workdir, baseBranch, workBranch}
app  → user_message {text}
srv  → assistant_delta … tool_call … tool_result … diff …
srv  → session_done
app  → create_pr {title}
srv  → pr_created {url}
```

When `permissionMode` is `ask`, mutating tools pause with a
`permission_request`; the app replies with `permission_response`. When it is
`plan`, mutating tools are described but not executed.

### Agent task checklist

The agent may call the `update_tasks` tool to maintain a short working list.
After each successful call the server emits a full `task_list` snapshot:

```json
{
  "type": "task_list",
  "sessionId": "…",
  "tasks": [
    { "id": "1", "content": "Read auth module", "status": "completed" },
    { "id": "2", "content": "Add unit tests", "status": "in_progress" }
  ]
}
```

`status` is one of `pending`, `in_progress`, `completed`, `cancelled`. On
session reattach the server re-sends the current list when non-empty.

### Resume / transcript replay

The agent runs in the **desktop** process. When the phone's WebSocket drops
(or the app is backgrounded and the OS tears the socket down), the desktop
keeps working — the `AgentSession` lives in `globalSessions` and continues
streaming events. The phone never gets those events until it reconnects.

On reattach (the app re-opens a recent session by sending `create_session`
with the same `sessionId`), the server sends, in order:

1. `session_created` (re-emitted with the same workdir / branches)
2. `task_list` (if any)
3. `goal_status` (active or last-achieved)
4. `transcript_replay` (if any events buffered)

`transcript_replay.events` is an ordered list of the events the phone
missed. Each event uses the same `type` discriminator as the live wire
(`assistant_delta`, `tool_call`, `tool_result`, `diff`) plus a `user`
event carrying the prompt the agent received for that turn — the server's
authoritative view, which may include messages the user typed while the
app was disconnected.

`truncated: true` means the rolling buffer dropped earlier events to stay
under the server-side cap. `isLive: true` means the agent is still
working on the current turn (no terminal `session_done` yet) so the
client can show the running indicator without waiting for the next live
event. After the replay, the same WebSocket continues to receive new
events normally.

### `/goal` completion condition

The coding composer accepts a `/goal` slash command as a normal `user_message`:

| Input | Effect |
|-------|--------|
| `/goal <condition>` | Set (or replace) the session goal and start working. Condition max 4000 chars. |
| `/goal` | Report active or last-achieved goal status (`goal_status`). |
| `/goal clear` | Clear an active goal early. Aliases: `stop`, `off`, `reset`, `none`, `cancel`. |

While a goal is **active**, the desktop agent does not return control after each
turn. After the agent finishes a turn, a small/fast evaluator model reads the
transcript and decides whether the condition is met:

- **No** → emit `goal_status` (`active` + reason) and start another turn.
- **Yes** → emit `goal_status` (`achieved`), then `session_done` with
  `stopReason: "goal_achieved"`.

```json
{
  "type": "goal_status",
  "sessionId": "…",
  "status": "active",
  "condition": "all tests in test/auth pass",
  "reason": "test suite has not been run yet",
  "turnsEvaluated": 1,
  "startedAt": 1710000000000,
  "elapsedMs": 45000,
  "message": "◎ /goal active: all tests in test/auth pass Running 45s. 1 turn(s) evaluated. Latest: test suite has not been run yet"
}
```

On reattach the server re-sends the active goal (or last achieved status) when
present. Evaluation uses `APC_GOAL_EVAL_MODEL` when set; otherwise a provider
default small model. Offline / `APC_MOCK=1` uses a transcript heuristic.

### Local model load progress

When the coding session runs a desktop Metal / MLX model, the server emits
`model_status` frames as weights load into memory and tokens generate:

```json
{ "type": "model_status", "sessionId": "…", "status": "loading", "hubID": "mlx-community/gemma-3-4b", "message": "Loading model weights into memory…" }
{ "type": "model_status", "sessionId": "…", "status": "generating", "hubID": "mlx-community/gemma-3-4b", "message": "Generating…" }
{ "type": "model_status", "sessionId": "…", "status": "done" }
```

`status` is `loading`, `generating`, or `done`. The app shows a "Loading
model…" indicator while `loading`, switches to "Generating…" while
`generating`, and clears it on `done`, the first `assistant_delta`, or
`session_done`. Clients that don't render the banner may ignore the frame.
