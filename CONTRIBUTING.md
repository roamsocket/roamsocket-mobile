# Contributing to RoamSocket

Thanks for helping build RoamSocket. This guide is short on purpose — the
real invariants live in **[AGENTS.md](./AGENTS.md)**. Read it before opening
a PR.

## Quick checklist

Before opening a PR, every box below should be tickable. If any is red, the PR
isn't ready.

- [ ] **Read [AGENTS.md](./AGENTS.md)** end to end if you haven't touched this
      area before
- [ ] **Protocol changes** updated the TS schema **and** Swift Codable **and**
      `docs/protocol.md` (never one-sided)
- [ ] **iOS structural changes** (new Swift file, edited `project.yml`) ran
      `npm run xcodegen` and committed the regenerated `.xcodeproj`
- [ ] **No secrets, no build output, no `node_modules/`** in the diff
- [ ] **Verification passes:**
      ```bash
      npm run typecheck:server      # TypeScript
      cd ios/AnyProvCore && swift test   # Foundation package
      npm run smoke                 # only if you touched the server / protocol
      ```
- [ ] **Commit messages** are complete sentences, explain *why* for protocol,
      security, or theme changes

## Code style

- TypeScript/JS: **Biome** at the root (`npm run lint` / `npm run format`).
  Two-space indent, single quotes, semicolons, LF line endings.
- Swift: **SwiftFormat** (`brew install swiftformat`, then
  `npm run format:swift`). Four-space indent, max line length 120.
- See `.editorconfig` for cross-editor defaults.

> Lint/format enforcement at the repo level is being rolled in — the baseline
> configs are present but not yet wired to CI. Help finishing that is welcome.

## Where to work

| Area | Primary paths |
|------|---------------|
| iOS app UI | `ios/App/Sources/Features/...` |
| Reusable Swift | `ios/AnyProvCore/Sources/AnyProvCore/...` (no Xcode needed) |
| Android app UI | `android/app/src/main/kotlin/...` |
| Reusable Kotlin | `android/RoamSocketCore/src/main/kotlin/...` (no Android needed) |
| Desktop server | `desktop-server/src/...` |
| Wire protocol | `desktop-server/src/protocol.ts` (canonical) + Swift mirror + Kotlin mirror + `docs/protocol.md` |
| Theme | `ios/App/Sources/DesignSystem/Theme.swift` + `android/app/.../ui/theme/Color.kt` + `desktop-server/src/renderer/styles.css` |
| Marketplace | `desktop-server/src/marketplace/` + iOS `AnyProvCore/Marketplace` |

## Branch names

We use `<type>/<scope>-<name>` for human-driven work and `<type>/auto-<yyyyMMdd>-<short-hash>` for agent runs.

| Type | When | Example |
|------|------|---------|
| `feat/` | new feature, additive change | `feat/android/chat-mvp` |
| `fix/` | bug fix | `fix/sidebar-overlap` |
| `refactor/` | restructure without behavior change | `refactor/extract-aimodel` |
| `chore/` | tooling, deps, non-functional | `chore/bump-compose-bom` |
| `docs/` | documentation only | `docs/agent-loop` |
| `feature/` | legacy — keep, but prefer `feat/` | `feature/vision-copy-qr` (older) |

For multi-platform work, prefix with the platform so reviewers can tell at a
glance which surface the PR touches:

- `feat/android/<name>` — Android-side work
- `feat/ios/<name>` — iOS-side work
- `feat/server/<name>` — desktop server

When the same change touches both sides (e.g. protocol), use `feat/<area>/<name>`
(e.g. `feat/protocol/agent-task-list`) and the PR body must list which side
each commit lands on.

Agent-driven work uses `feat/auto-<yyyyMMdd>-<short-hash>` (the harness
picks the hash). One PR per agent run.

## PR titles

`<Scope>: <Imperative description>` — keep it under 70 chars so it doesn't
truncate in the list view.

**Scope** is one of:

- **Conventional-commit type** when the change is mostly one kind: `feat:`, `fix:`, `refactor:`, `chore:`, `docs:`
- **Platform or component** when it's specific: `Android:`, `iOS:`, `Server:`, `Wire protocol:`, `Chat:`, `Code:`, `Settings:`, `Theme:`, `Build:`
- Combine for scoping: `Android: Chat MVP — providers, encrypted key store, model picker, chat screen`

The description is **imperative mood**, no trailing period, capitalized after
the colon. The body is where the details go.

Good: `Android: Chat MVP — provider registry, key store, screen`
Good: `Server: SSH auto-setup + install-service CLI (mac/linux/win)`
Good: `feat: replace TUI with OpenAI/Anthropic proxy + launch shortcuts`
Bad:  `added chat screen` (past tense, lowercase)
Bad:  `Android: chat MVP.` (trailing period, lowercase)

## PR body

Always fill in the full template (`.github/pull_request_template.md`):

- **Summary** — 1–3 sentences. What and why.
- **Type of change** — tick the right boxes (Bug fix / New feature / etc.).
- **Areas touched** — tick every box that applies. The Android categories
  are there for new work; legacy iOS / server boxes still apply.
- **Protocol changes** — if any wire field changed, paste the diff of
  `desktop-server/src/protocol.ts` and confirm the Swift + Kotlin mirrors
  and `docs/protocol.md` were updated in the same commit.
- **Verification** — paste the actual commands you ran and their outcome.
  Don't just check the box; the reviewer will skim your command output
  before approving. Example:
  ```
  - `cd desktop-server && npm run typecheck:server` → clean
  - `cd android && ./gradlew :RoamSocketCore:test` → 25/25 pass
  - `cd android && ./gradlew :app:assembleDebug` → app-debug.apk produced
  ```
- **Checklist** — at minimum: read AGENTS.md, no secrets, no build
  output in diff, commit messages explain *why* for protocol/security/theme.

## Commit messages

Single-line summaries are fine for small fixups. For anything that touches
protocol, security, theme, or shared infrastructure, the body must explain
**why** in 1–3 sentences. Future agents (and humans) read these when
debugging or reverting.

## Research notes

If you discover something non-obvious (a provider quirk, a Swift gotcha, a
build trap), write it under **`.research/`** with sources and link it from
`AGENTS.md`'s research table. Don't scatter `.md` notes at the repo root.

## Things that will get your PR closed fast

- Renamed a protocol field on only one side
- Added a Swift file under `ios/App/Sources` without regenerating the Xcode project
- Bumped theme tokens without updating both iOS and Electron
- Logged an API key or token (even partially)
- Hand-edited `ios/RoamSocket.xcodeproj` instead of `project.yml`

## Questions?

Open an issue or ask in a PR. The repo is actively maintained by
[@roamsocket-ai](https://github.com/roamsocket-ai).