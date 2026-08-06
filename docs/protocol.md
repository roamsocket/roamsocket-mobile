# Wire protocol

The iOS app and the desktop server speak a small JSON protocol. Pairing is over
HTTP; the coding session runs over a WebSocket. The canonical definitions live
in `desktop-server/src/protocol.ts` (zod) and are mirrored by the Swift Codable
types in `ios/AnyProvCore/Sources/AnyProvCore/Server/Protocol.swift`. Keep all
three in sync.

## HTTP

### `GET /health`
```json
{ "ok": true, "name": "anyprov-code desktop", "version": "0.1.0" }
```

### `POST /pair`
Request:
```json
{ "code": "123456", "deviceName": "Julian's iPhone" }
```
Response `200`:
```json
{ "token": "…", "serverName": "anyprov-code desktop", "serverVersion": "0.1.0" }
```
`401` on a wrong code. The `token` is a bearer token used to open the WebSocket.

## WebSocket `GET /session?token=…`

Every frame is a JSON object with a `type` discriminator.

### App → server

| type                  | fields |
|-----------------------|--------|
| `create_session`      | `sessionId?`, `repo{fullName, baseBranch?, workBranch, githubToken?}`, `environment?`, `model{provider, model, effort, apiKey, baseUrl?, apiStyle?}`, `permissionMode`, `skills?` (string[]), `mcpServers?` (`MCPServer[]`: `id`, `name`, `description`, `command`, `args`, `env`, `isEnabled`) |
| `user_message`        | `sessionId`, `text` |
| `permission_response` | `sessionId`, `requestId`, `decision` (`allow`\|`deny`) |
| `interrupt`           | `sessionId` |
| `create_pr`           | `sessionId`, `title`, `body` |
| `git_publish`         | `sessionId`, `message`, `commit`, `push`, `openPr` |
| `terminal_open`       | `sessionId`, `terminalId?`, `cols?`, `rows?` |
| `terminal_input`      | `terminalId`, `data` |
| `terminal_kill`       | `terminalId` |
| `file_list`           | `sessionId`, `path` |
| `file_read`           | `sessionId`, `path` |
| `port_list`           | `sessionId` |
| `tunnel_start`        | `sessionId`, `port`, `provider` (`auto`\|`ngrok`\|`cloudflare`\|`localtunnel`\|`bore`) |
| `tunnel_stop`         | `sessionId`, `tunnelId` |
| `tunnel_list`         | `sessionId` |

`permissionMode` is one of `acceptEdits`, `plan`, `ask` (the composer's
permission pill). `provider` is one of `anthropic`, `openai`, `google`, `groq`,
`openrouter`, `xai`, `mistral`, or a custom id `custom:<slug>`.

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
| `diff`               | `sessionId`, `path`, `patch`, `added`, `removed` |
| `permission_request` | `sessionId`, `requestId`, `tool`, `summary` |
| `session_done`       | `sessionId`, `stopReason?` |
| `pr_created`         | `sessionId`, `url` |
| `git_result`         | `sessionId`, `action`, `ok`, `detail`, `url?` |
| `file_list_result`   | `sessionId`, `path`, `entries[]`, `diff?`, `changes?` |
| `file_read_result`   | `sessionId`, `path`, `content`, `truncated`, `diff?` |
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
