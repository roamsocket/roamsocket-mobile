# Wire protocol

The iOS app and the desktop server speak a small JSON protocol. Pairing is over
HTTP; the coding session runs over a WebSocket. The canonical definitions live
in `desktop-server/src/protocol.ts` (zod) and are mirrored by the Swift Codable
types in `ios/AnyProvCore/Sources/AnyProvCore/Server/Protocol.swift`. Keep all
three in sync.

## Local discovery (Bonjour / mDNS)

The desktop companion advertises itself on the LAN so phones can list nearby
servers without typing an IP:

| | |
|--|--|
| Service type | `_codesocket._tcp` |
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
{ "ok": true, "name": "CodeSocket desktop", "version": "0.1.0", "publicUrl": "https://…", "tunnelStatus": "up" }
```

### `POST /pair`
Request:
```json
{ "code": "123456", "deviceName": "Julian's iPhone" }
```
Response `200`:
```json
{ "token": "…", "serverName": "CodeSocket desktop", "serverVersion": "0.1.0", "publicUrl": "https://…?" }
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
| `diff`               | `sessionId`, `path`, `patch`, `added`, `removed` |
| `permission_request` | `sessionId`, `requestId`, `tool`, `summary` |
| `session_done`       | `sessionId`, `stopReason?` |
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
