# AGENTS.md — working in RoamSocket

Instructions for AI coding agents (Codex, Cursor, Grok, etc.) working in this repository.

## What this project is

**RoamSocket** is an open-source, native **iOS** client plus a **desktop companion** that runs the coding agent.

| Mode | Path | Needs server? |
|------|------|----------------|
| **Chat** | iOS app → provider `/v1` APIs with the user's API key | No |
| **Code** | iOS app ↔ desktop server over WebSocket | Yes — clones repos, runs tools, streams diffs, opens PRs |

BYOK: Anthropic, OpenAI, Ollama/OpenAI-compatible, Groq, OpenRouter, xAI, Mistral, MiniMax (Google chat/listing only for agent).

## Repo map

```
roamsocket/  (repo may still be checked out as code-mobile-ai)
├── ios/                      # SwiftUI app + AnyProvCore package
│   ├── App/Sources/          # UI (edit these, not the generated xcodeproj)
│   ├── AnyProvCore/         # Foundation-only: providers, GitHub, protocol, skills
│   ├── project.yml           # XcodeGen source of truth
│   ├── RoamSocket.xcodeproj/  # GENERATED — do not hand-edit
│   └── scripts/              # watch-xcode.sh, xcode helpers
├── desktop-server/           # Node/TS companion + Electron UI
│   ├── src/                  # server, agent, tools, electron, renderer
│   └── scripts/smoke.ts      # offline e2e protocol test
├── docs/protocol.md          # Human-readable wire protocol
├── marketplace/              # Pointer docs → external official catalog host
├── landing/                  # Pointer docs → roamsocket/roamsocket-site
├── AGENTS.md                 # This file
└── CLAUDE.md                 # Agent-oriented notes
```

### iOS app structure (`ios/App/Sources`)

| Path | Role |
|------|------|
| `App/` | App entry, `AppState`, `RootView`, Keychain |
| `DesignSystem/` | `Theme`, shared components |
| `Features/Chat/` | Main chat UI (default landing) |
| `Features/Code/` | `CodeHomeView` — coding entry |
| `Features/Session/` | Coding session, tools, new session |
| `Features/Settings/` | Keys, GitHub, server pairing |
| `Features/Sidebar/` | Projects drawer |
| `Features/Skills/` | Skills + MCP management |
| `Features/Environments/`, `ModelPicker/`, `Repositories/` | Pickers |

### AnyProvCore (`ios/AnyProvCore`)

Pure Foundation (no SwiftUI). Safe to build/test without Xcode:

- `Providers/` — model listing + chat clients  
- `GitHub/` — PAT / device-flow, repo list  
- `Server/` — Codable protocol + WebSocket client (**must mirror** TS)  
- `Marketplace/` — multi-source catalog (connectors, skills, plugins, Metal)  
- `Skills/`, `Artifacts/`, `Sync/`

### Desktop server (`desktop-server/src`)

| Path | Role |
|------|------|
| `index.ts` | HTTP `/health`, `/pair` + WS `/session`; exports `startServer()` |
| `protocol.ts` | **Canonical** Zod schemas |
| `sessions.ts` | Session lifecycle, workdir, PR |
| `agent/loop.ts` | Tool-use agent loop |
| `providers/` | anthropic, openai-compatible, mock |
| `tools/` | bash, files, etc. |
| `git/` | clone, branch, commit, push, diff |
| `electron/` | Main process, tray, safeStorage |
| `renderer/` | Desktop client UI (vanilla TS + CSS) |
| `marketplace/` | Multi-source marketplace fetch/merge (connectors, skills, plugins, Metal) |

Default port: **4319**.

### Marketplace (owner + user catalogs)

- **Official repo (separate external host):** [codesocket-ai/codesocket-marketplace](https://github.com/codesocket-ai/codesocket-marketplace)
- **Default catalog URL:** `https://raw.githubusercontent.com/codesocket-ai/codesocket-marketplace/main/catalog.json` (host path is external; product name is RoamSocket)
- **Authoring guide:** that repo’s README (“How to make your own marketplace”).
- **Desktop:** Settings → Marketplace; applies to composer connectors/plugins + Metal list.
- **iOS:** Settings → Marketplace; same sources feed connectors, skill browse, Metal recommended.
- Users can **add extra marketplace repos** (raw `catalog.json` URL, GitHub blob/tree, or `owner/repo`).
- User skills/MCP git repos (`APC_SKILLS_REPO` / `APC_MCP_REPO`) remain separate private sync.
- This monorepo’s `marketplace/` folder is a **pointer only** — do not put the live catalog here.

### Marketing site

- **Repo:** [roamsocket/roamsocket-site](https://github.com/roamsocket/roamsocket-site)
- Cloudflare Workers static assets (`public/` + Wrangler). Edit and deploy there.
- This monorepo’s `landing/` folder is a **pointer only** — do not put the live site here.

## Critical invariants

1. **Protocol triple must stay in sync** when changing wire messages:
   - `desktop-server/src/protocol.ts` (canonical)
   - `ios/AnyProvCore/.../Server/Protocol.swift`
   - `docs/protocol.md`
2. **Xcode project is generated.** After adding/removing Swift files under `ios/App/Sources` or editing `ios/project.yml`, run:
   ```bash
   cd ios && xcodegen generate
   ```
   Or: `ios/scripts/watch-xcode.sh --once`
3. **Do not commit** `ios/build/`, `desktop-server/out/`, `desktop-server/.vite/`, `node_modules/`, or secrets.
4. **Secrets:** keys/tokens on iOS go in Keychain (`KeychainSecretStore`). Server holds provider/GitHub tokens only for the session (Electron may use safeStorage for UI-entered keys). Never log full API keys.
5. **Theme:** cool blue-grey shared with Electron. Tokens live in:
   - `ios/App/Sources/DesignSystem/Theme.swift`
   - `desktop-server/src/renderer/styles.css` (`:root` CSS variables)  
   Accent is `#6aa9ff`, not terracotta. Keep them aligned when changing UI colors.

## Commands

### Desktop server

```bash
cd desktop-server
npm install
npm run dev              # watch (tsx)
npm start                # needs prior build
npm run typecheck        # server + electron
npm run typecheck:server
npm run smoke            # offline e2e: pair → session → tools → PR (APC_MOCK)
APC_MOCK=1 npm start    # mock agent, no API key
```

Electron:

```bash
cd desktop-server
npm run electron:dev
npm run electron:package
```

Env: `PORT` (default 4319), `APC_MOCK=1`, `APC_NAME`.

### iOS

```bash
cd ios
xcodegen generate                 # project.yml → .xcodeproj
open RoamSocket.xcodeproj

cd AnyProvCore
swift build
swift test                        # protocol + provider tests
```

```bash
# optional continuous regen while adding files
./ios/scripts/watch-xcode.sh
```

### Marketing site (Cloudflare Workers)

Lives in **[roamsocket/roamsocket-site](https://github.com/roamsocket/roamsocket-site)** (not this monorepo).

```bash
git clone https://github.com/roamsocket/roamsocket-site.git
cd roamsocket-site
npm install
npm run dev          # wrangler dev — http://localhost:8787
npm run deploy       # requires wrangler login
```

## How to change common things

### Wire protocol / new WS message type

1. Add Zod schema + union member in `desktop-server/src/protocol.ts`
2. Mirror Codable types in `ios/AnyProvCore/.../Server/Protocol.swift`
3. Handle on server (`sessions.ts` / agent / tools) and client (`ServerClient` + UI)
4. Update `docs/protocol.md`
5. Prefer extending `npm run smoke` if the flow is testable offline

### New iOS screen or Swift file

1. Add under `ios/App/Sources/Features/...` (or `DesignSystem/`)
2. Wire navigation from `RootView` / sidebar / existing feature
3. Use `Theme` and existing components — don't invent a second palette
4. Run `xcodegen generate` (or watch script)
5. Keep logic that is reusable/testable in `AnyProvCore` when possible

### New agent tool

1. Implement in `desktop-server/src/tools/`
2. Register in tools index / agent loop
3. Ensure permission modes (`acceptEdits` | `plan` | `ask`) are respected
4. Stream `tool_call` / `tool_result` (and `diff` when files change) via protocol

### Provider / model support

- iOS listing: `AnyProvCore/Providers/`
- Server agent: `desktop-server/src/providers/`
- OpenAI-compatible base URL is the path for Ollama and custom endpoints

## Style and product conventions

- **iOS:** SwiftUI, iOS 17+, `@EnvironmentObject` / `AppState` for global state, feature folders by screen area.
- **Server:** TypeScript ESM, Zod at boundaries, no unnecessary new deps.
- **Desktop UI:** No web fonts in Electron shell; system fonts; CSS variables in `styles.css`.
- **Copy:** Plain product language (pair, keys, repository, pull request) — not internal system jargon in UI strings.
- Prefer small, focused diffs. Don't rewrite unrelated features.

## What not to do

- Don't hand-edit `ios/RoamSocket.xcodeproj` as the primary workflow — edit `project.yml` / sources and regenerate.
- Don't commit build products or `.xcuserstate`.
- Don't break chat-without-server: chat must keep working with only a provider key.
- Don't add a second theme or terracotta accents without an explicit product decision.
- Don't invent protocol fields on one side only.

## Verification checklist before claiming done

| Change area | Verify |
|-------------|--------|
| Desktop server | `cd desktop-server && npm run typecheck:server` |
| Agent / protocol flow | `cd desktop-server && npm run smoke` |
| Electron types | `cd desktop-server && npm run typecheck:electron` |
| AnyProvCore | `cd ios/AnyProvCore && swift test` |
| iOS UI | Build in Xcode simulator after `xcodegen generate` |
| Protocol | TS + Swift + `docs/protocol.md` still agree |

## Further reading

- Root `README.md` — product overview  
- `ios/README.md` — app + AnyProvCore  
- `desktop-server/README.md` — server + Electron  
- `docs/protocol.md` — wire protocol  
- `CLAUDE.md` — optional agent tooling notes (hooks, session defaults)  
