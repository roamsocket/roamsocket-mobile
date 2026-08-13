# CLAUDE.md — AI coding agent project guide

Tooling-oriented notes for agents working in this repository. For the full architecture map, commands, and invariants, see **[AGENTS.md](./AGENTS.md)** first.

## Mission

You are working on **RoamSocket**: a native iOS coding client with a desktop companion that runs the real coding agent (clone → tools → diffs → PR). Users bring their own API keys and endpoints.

Prefer **correctness over drive-by refactors**. Match existing patterns in the feature area you touch.

## Read first

1. `AGENTS.md` — architecture map, invariants, verification commands  
2. `docs/protocol.md` — if the task touches app ↔ server messaging  
3. `ios/README.md` or `desktop-server/README.md` for area-specific detail  
4. `.research/` — version-controlled research notes (e.g. `provider-response-quirks.md` for iOS chat parser work). **Read the relevant file before editing that area.**  

## Default working style

- Explore with targeted reads/greps before large edits.
- Keep protocol, theme, and security invariants from `AGENTS.md`.
- After adding Swift files under `ios/App/Sources` or changing `ios/project.yml`, regenerate the Xcode project (`xcodegen generate` or `ios/scripts/watch-xcode.sh --once`).
- Run the smallest relevant verification (smoke, `swift test`, typecheck) before claiming a fix is done.
- Do not commit secrets, `ios/build/`, Electron `out/` / `.vite/`, or user-specific Xcode state.

## Editor hooks

Configured in `.claude/settings.json` (path used by some agent CLIs):

| Hook | When | What |
|------|------|------|
| `SessionStart` | Every new session | Runs `.claude/hooks/session-start-context.sh` — prints branch, last commit, dirty files, toolchain versions, deps state, key paths |
| `PostToolUse` on Edit/Write/MultiEdit | After file edits | Runs `.claude/hooks/post-edit-xcodegen.sh` when `ios/project.yml` changes |
| `PostToolUse` on Edit/Write/MultiEdit | After file edits | Runs `.claude/hooks/post-edit-format.sh` — Biome-formats edited TS/JS/JSON files (no-op if Biome not installed) |

The xcodegen hook regenerates the Xcode project when iOS sources / `project.yml` change so new Swift files show up in Xcode without a manual step. If xcodegen is missing, install with `brew install xcodegen`.

## Where to work (quick)

| Task | Primary paths |
|------|----------------|
| Chat / sidebar / projects UI | `ios/App/Sources/Features/Chat`, `Sidebar`, `Chats` |
| Coding session UI | `ios/App/Sources/Features/Code`, `Session` |
| Settings / pairing / keys | `ios/App/Sources/Features/Settings` |
| Theme / shared controls | `ios/App/Sources/DesignSystem` |
| Providers, GitHub, WS client | `ios/AnyProvCore/Sources/AnyProvCore` |
| Agent loop / tools / git | `desktop-server/src/agent`, `tools`, `git` |
| Wire protocol (canonical) | `desktop-server/src/protocol.ts` → mirror Swift + docs |
| Electron window / tray | `desktop-server/src/electron` |
| Desktop client UI | `desktop-server/src/renderer` |
| Marketing page | separate repo: [roamsocket/roamsocket-site](https://github.com/roamsocket/roamsocket-site) (`landing/` is a pointer only) |

## Theme (do not regress)

Cool blue-grey, shared with Electron:

- Background `#0B0D10`, surfaces `#14181D` / `#1B2026`
- Accent `#6AA9FF` (send / primary actions)
- iOS: `Theme.swift` · Desktop: `renderer/styles.css` `:root`

Primary buttons on accent should use dark ink (`Theme.background` / `#0b0d10`), not pure white, for contrast consistency with the Electron shell.

## High-risk change patterns

### Protocol change

Canonical order:

1. `desktop-server/src/protocol.ts`  
2. `ios/AnyProvCore/.../Server/Protocol.swift`  
3. Handlers on both ends  
4. `docs/protocol.md`  
5. Extend `desktop-server` smoke test if possible  

Never ship a one-sided field rename.

### New iOS file not in the Xcode project

Symptom: file exists on disk but Xcode doesn't compile it. Cause: XcodeGen. Fix: regenerate from `project.yml`. Prefer sources under `App/Sources` so XcodeGen picks them via the glob in `project.yml`.

### Breaking local network pairing

`Info.plist` allows cleartext/local networking for LAN `http`/`ws` to the desktop server. Don't tighten ATS casually during feature work; note it for any store-bound change.

## Preferred verification

One-shot (recommended when wrapping up):

```bash
npm run verify            # all checks
npm run verify:ios        # iOS only
npm run verify:server     # server only
npm run verify:protocol   # protocol triple sanity only
```

Or run individual checks:

```bash
# Protocol / agent offline
cd desktop-server && npm run smoke

# Server types
cd desktop-server && npm run typecheck:server

# Core package (no Xcode)
cd ios/AnyProvCore && swift test

# iOS project after structural changes
cd ios && xcodegen generate
```

Use `APC_MOCK=1` when exercising the server without provider keys.

## PR / commit expectations

- Small, reviewable commits with complete sentences in messages.
- Summarize *why* when protocol, security, or theme changes.
- Don't include generated build trees; `ios/build/` is gitignored.

## Product boundaries

- **Chat** works without the desktop server (direct provider APIs).  
- **Code** requires pairing + server for real tools/git/PR.  
- Skills, MCP, terminal, and workspace features may span AnyProvCore + server — grep for existing managers before inventing parallel systems.

When unsure, prefer extending existing types and managers over new top-level abstractions.
