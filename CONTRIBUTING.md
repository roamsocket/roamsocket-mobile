# Contributing to RoamSocket

Thanks for helping build RoamSocket. This guide is short on purpose — the
real invariants live in **[AGENTS.md](./AGENTS.md)**. Read it before opening
a PR.

The branch, commit, PR, file, and identifier contracts below are adapted
from the project's "naming conventions" doc and are mandatory for human
contributors and AI agents alike. If something here collides with
`AGENTS.md`, `AGENTS.md` wins — this file covers *style*, `AGENTS.md`
covers *correctness*.

## Quick checklist

Before opening a PR, every box below should be tickable. If any is red, the PR
isn't ready.

- [ ] **Read [AGENTS.md](./AGENTS.md)** end to end if you haven't touched this
      area before
- [ ] **Branch name** matches `<type>/<kebab-slug>` (no auto/random branches —
      see [Branch names](#1-branch-names))
- [ ] **Commit subject** is `<type>(<scope>): <summary>` (Conventional Commits,
      imperative, lowercase, no period — see [Commit messages](#2-commit-messages))
- [ ] **PR title** matches the commit subject it summarizes
      (see [PR titles](#3-pr-titles))
- [ ] **Protocol changes** updated the TS schema **and** Swift Codable **and**
      Kotlin mirror **and** `docs/protocol.md` (never one-sided)
- [ ] **iOS structural changes** (new Swift file, edited `project.yml`) ran
      `npm run xcodegen` and committed the regenerated `.xcodeproj`
- [ ] **No secrets, no build output, no `node_modules/`** in the diff
- [ ] **Verification passes:**
      ```bash
      npm run typecheck:server      # TypeScript
      cd ios/AnyProvCore && swift test   # Foundation package
      npm run smoke                 # only if you touched the server / protocol
      ```
- [ ] **Commit body** explains *why* for protocol, security, theme, or shared
      infra changes (1–3 sentences)

## Code style

- TypeScript/JS: **Biome** at the root (`npm run lint` / `npm run format`).
  Two-space indent, single quotes, semicolons, LF line endings.
- Swift: **SwiftFormat** (`brew install swiftformat`, then
  `npm run format:swift`). Four-space indent, max line length 120.
- Kotlin: standard `kotlin.code.style=official` settings, four-space indent,
  matched via `android/gradle.properties` / IDE.
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

## Naming conventions

**Scope:** every human-driven and AI-agent-driven change to this repo.
**Status:** active contract. Not yet enforced by lint/CI; reviewers apply it
on PR review. If you spot a violation, ask for the rename in review rather
than auto-correcting mid-review.

This file is the RoamSocket adaptation of a shared naming-conventions
template, tuned to our stack: Swift (iOS), Kotlin (Android), TypeScript /
Node (desktop server), Electron renderer, and a triplicated wire protocol.
There is no React, no Vite, no SCSS, and no Firebase here.

The long-form companion doc — with more examples, decision rationale, and
a quick-reference decision tree for AI agents — lives at
[`docs/naming-conventions.md`](./docs/naming-conventions.md). When the
contract here and the long form disagree, **this file wins**.

### TL;DR

| Thing | Format | Example |
| --- | --- | --- |
| Branch | `<type>/<kebab-slug>` | `fix/canonical-og-from-route` |
| Commit subject | `<type>(<scope>): <summary>` | `fix(seo): derive canonical + og:image from the current route` |
| PR title | Same as commit subject | `feat(ios): add sidebar resume` |
| Swift file (type / view / view model) | `PascalCase.swift` | `ServerClient.swift`, `RootView.swift` |
| Kotlin file (class / screen / VM) | `PascalCase.kt` | `CodeSessionRepository.kt`, `ChatScreen.kt` |
| TypeScript module (server / renderer) | `kebab-case.ts` | `tunnel-clis.ts`, `chat-stream.ts` |
| TypeScript test | `<unit>.test.ts` next to the unit | `tunnel-clis.test.ts` |
| Swift test (XCTest) | `<Unit>Tests.swift` | `ProtocolTests.swift` |
| Kotlin test (JVM) | `<Unit>Test.kt` | `ProtocolRoundtripTest.kt` |
| Root config | lowercase, dotfile or one-word | `vite.config.ts`, `wrangler.jsonc`, `eslint.config.js` |
| Env var / secret | `SCREAMING_SNAKE_CASE` | `APC_NAME`, `APC_MOCK`, `PORT` |
| Wire-protocol message kind | `snake_case` string literal | `tool_call`, `agent_message`, `diff` |
| TS type / Swift type / Kotlin type | `PascalCase` | `ClientMessage`, `ServerMessage`, `AIModel` |

### 1. Branch names

**Format:**

```
<type>/<short-kebab-slug>
```

`<type>` is one of:

| Type | Use for |
| --- | --- |
| `feat` | New user-facing capability |
| `fix` | Bug fix |
| `chore` | Tooling, deps, refactors with no user-visible change |
| `docs` | Documentation only |
| `refactor` | Code restructuring with no behavior change |
| `perf` | Performance improvement |
| `test` | Adding or fixing tests only |
| `build` | Build system changes |
| `ci` | CI workflow changes only |
| `style` | Visual/cosmetic only (formatting, spacing) |
| `hotfix` | Urgent production fix off `main` (rare) |

`<short-kebab-slug>` is lowercase, dash-separated, ≤ ~40 chars, no trailing
dash, no double dash. Scope first, then feature:

- `feat/ios/<slug>` — iOS-side work
- `feat/android/<slug>` — Android-side work
- `feat/server/<slug>` — desktop server
- `feat/protocol/<slug>` — wire-protocol changes that touch multiple sides
- `feat/renderer/<slug>` — Electron renderer UI
- `feat/theme/<slug>` — visual tokens that span iOS + Android + renderer
- `feat/marketplace/<slug>` — marketplace catalog / Skills / MCP / Metal
- `chore/deps/<slug>` — dependency bumps
- `fix/ios/<slug>`, `fix/android/<slug>`, `fix/server/<slug>` — same idea

When the change clearly belongs to one platform, prefix the slug with that
platform. When the change is cross-cutting, use one of the area prefixes
above (`server`, `protocol`, `renderer`, `theme`, `marketplace`). Web is not
a platform here — never use `web/`.

**Suffixes**

- `-pr<N>` — append when the branch is the Nth iteration of the same logical
  change (a PR sent back for review and re-pushed). Bump the number instead
  of mutating the slug: `fix/canonical-og-from-route-pr2`.

**Rules**

- **No `main` work directly.** Everything goes through a branch + PR.
- **No auto or random-string branches.** Never create or keep a
  `feat/auto-<yyyyMMdd>-<id>` branch (or any opaque/random-string branch).
  Every branch gets a human-readable `<type>/<kebab-slug>` from the start.
  If an auto branch ever appears, rename it before the first commit:

  ```bash
  git branch -m <current-auto-name> chore/naming-conventions
  # or, for a feature PR:
  git branch -m <current-auto-name> feat/<area>/<slug>
  ```

  Push the renamed branch and delete the old remote ref. Existing
  `feat/auto-*` branches on `origin` are **legacy** and stay as-is until
  their PR lands; do not add new ones.

- **No personal names, external ticket IDs, or build numbers in the slug.**
  The `-pr<N>` suffix is the only numeric suffix allowed.
- **Scope goes in the slug when it matters.** Use the platform/area prefixes
  above whenever the change is specific to that surface; otherwise a plain
  `fix/<slug>` is fine.
- **Legacy types.** `feature/` (no `s`) is a pre-existing legacy prefix on a
  handful of older branches (`feature/vision-copy-qr`, etc.). Keep those
  branches; do not create new `feature/` branches — use `feat/`.

### 2. Commit messages

Conventional Commits. Subject line:

```
<type>(<scope>): <summary>
```

- **`<type>`** — same set as branch types, plus `revert`.
- **`<scope>`** — optional, lowercase. Use the same set of platforms/areas
  you would put in a branch slug: `ios`, `android`, `server`, `renderer`,
  `protocol`, `theme`, `marketplace`, `git`, `ci`, `deps`, `docs`. Compound
  scopes are allowed with `+` (`feat(ios+android): ...`).
- **`<summary>`** — imperative mood, lowercase first letter, no trailing
  period, ≤ 72 chars. Describe the *what* and *why*, not the diff.
- **Body** (optional) — 1–3 sentences explaining the *why* for anything
  protocol, security, theme, or shared-infra related. Future agents (and
  humans) read these when debugging or reverting.
- **Footer** — use a `BREAKING CHANGE: <one-liner>` footer for any public-
  API change: a wire-protocol field rename, an env-var rename, a Swift
  public-API change consumed by another module.

**Examples**

```
feat(ios): add sidebar resume for chats
fix(server): use credential helper for ops.ts pulls (auth parity with github.ts)
feat(protocol): add agent task checklist and desktop Metal listing
style(renderer): tighten chat composer spacing and hover states
chore(deps): bump react and react-dom to 19.2.7
docs: remove Convex references from README and integrations.md
```

**Notes**

- One commit per logical change. Squash `wip` / `fix typo` / `amend pr-N`
  commits before opening a PR (or before pushing the `-pr2` round).
- `style(renderer)` / `style(theme)` is the prefix for visual-only changes
  (spacing, colors, copy polish). Reserve `fix` for actual broken behavior.
- When a commit fixes a known issue, reference it in the body, not the
  subject: subject stays clean for log scanning.

### 3. PR titles

Same format as the commit subject: `<type>(<scope>): <summary>`. One PR = one
logical change. Title the PR after the *headline* change; put sub-changes in
the description. Match the title to the net change, not the branch name.

If the PR is a `-pr2` follow-up of a previous PR, the title stays the same —
the body carries the iteration note.

### 4. File and module names

Match the neighbors. The repo has three language surfaces plus shared
configs; each has its own convention.

#### Swift (iOS app + AnyProvCore)

| Kind | Format | Example |
| --- | --- | --- |
| UI view | `PascalCase.swift` | `RootView.swift`, `ChatView.swift` |
| View model / store | `PascalCase.swift` | `ChatViewModel.swift`, `VoiceSettingsStore.swift` |
| Service / manager | `PascalCase.swift` | `ServerClient.swift`, `SkillManager.swift` |
| Model / value type | `PascalCase.swift` | `AIModel.swift`, `MarketplaceModels.swift` |
| Protocol type | `PascalCase.swift` | `Protocol.swift` (in `Server/`) |
| Capability / capability detector | `PascalCase.swift` | `VisionCapability.swift` |
| Feature folder | `PascalCase` | `Features/Chat/`, `Features/Skills/` |
| Test | `<Unit>Tests.swift` | `ProtocolTests.swift` |

- One default (or only) public type per file; filename matches the type.
- Sub-types used only by the parent stay in the same file
  (`MarketplaceModels.swift` can declare both `MarketplaceEntry` and the
  parsing helper).
- No Swift `index.swift` re-export barrels inside `Features/` or
  `AnyProvCore/` subdirectories. Import the module directly.

#### Kotlin (Android app + RoamSocketCore)

| Kind | Format | Example |
| --- | --- | --- |
| Activity / application | `PascalCase.kt` | `MainActivity.kt`, `RoamSocketApplication.kt` |
| View / screen | `PascalCase.kt` | `ChatScreen.kt`, `SettingsScreen.kt` |
| View model | `PascalCase.kt` | `ChatViewModel.kt`, `SettingsViewModel.kt` |
| Repository / data source | `PascalCase.kt` | `DataStoreChatHistoryRepository.kt` |
| Service / network client | `PascalCase.kt` | `ServerDiscovery.kt`, `GitHubClient.kt` |
| Data class / sealed hierarchy | `PascalCase.kt` | `SessionConfig.kt` |
| Test | `<Unit>Test.kt` | `ProtocolRoundtripTest.kt` |

- Filename matches the primary type in the file.
- Package paths stay lowercase, dot-separated:
  `app.roamsocket.android.ui.chat`, `app.roamsocket.android.data`,
  `app.roamsocket.core.protocol`.
- No Kotlin re-export files (no `Package.kt` barrels inside `ui/...`).

#### TypeScript (desktop server + Electron renderer)

| Kind | Format | Example |
| --- | --- | --- |
| Module / lib / util | `kebab-case.ts` | `tunnel-clis.ts`, `code-sessions-store.ts` |
| Server entry / router | `kebab-case.ts` | `sessions.ts`, `pairing.ts` |
| Renderer module | `kebab-case.ts` | `chat-stream.ts`, `project-modals.ts` |
| Agent / tool / git submodule | `kebab-case.ts` | `agent/loop.ts`, `tools/bash.ts`, `git/ops.ts` |
| Zod schema / type-only module | `kebab-case.ts` | `protocol.ts`, `tools/types.ts` |
| Test | `<unit>.test.ts` next to the unit | `tunnel-clis.test.ts` |
| Electron main | `kebab-case.ts` | `electron/main.ts`, `electron/preload.ts` |
| HTML / CSS in renderer | lowercase, one word | `renderer/index.html`, `renderer/styles.css` |
| Memory / one-off scripts | `kebab-case.mjs` | `scripts/memory-activity-test.mjs` |

- One export per file. If a file holds a class + a Zod schema + a few
  helpers, the file name is the class (PascalCase) or the schema
  (`kebab-case.ts`); the helpers stay private to that file.
- No re-export barrels (`index.ts`) inside `desktop-server/src/<area>/`
  except at the package root for that area, and only when needed for
  ergonomics.
- Public types in TS modules are still `PascalCase`
  (`ClientMessage`, `ServerMessage`, `AIModel`) — the file casing and the
  type casing are different.

#### Configs, docs, and root

| Kind | Format | Example |
| --- | --- | --- |
| Root config | lowercase, dotfile or one-word | `vite.config.ts`, `wrangler.jsonc`, `eslint.config.js` |
| Docs (markdown) | `kebab-case.md` | `docs/protocol.md`, `.research/provider-response-quirks.md` |
| XcodeGen source | `project.yml` (fixed name) | `ios/project.yml` |
| Wrangler / cloud config | `wrangler.jsonc` / `wrangler.toml` | `desktop-server/wrangler.jsonc` |
| AGENTS / CONTRIBUTING | `AGENTS.md`, `CONTRIBUTING.md` (fixed) | — |

### 5. Identifiers inside code

#### Env vars / secrets

`SCREAMING_SNAKE_CASE`. Two namespaces:

- Anything exposed to the client at build time (`VITE_*` would be a Vite
  convention — we don't have a Vite app here).
- Server / integration secrets: `APC_*` for the desktop server and agents,
  `PORT` for the listen port, etc.

| Var | Meaning |
| --- | --- |
| `APC_MOCK=1` | Run the desktop server with a mock provider (no real API keys) |
| `APC_NAME` | Display name for this server instance |
| `APC_BIN_DIR` | Override binary lookup dir for tunnel CLIs |
| `APC_GOAL_EVAL_MODEL` | Override the model used for goal evaluation |
| `APC_GOAL_HEURISTIC=1` | Force the heuristic goal evaluator |
| `APC_SKILLS_REPO` / `APC_SKILLS_BRANCH` / `APC_SKILLS_TOKEN` | User Skills git sync |
| `APC_MCP_REPO` / `APC_MCP_BRANCH` / `APC_MCP_TOKEN` | User MCP git sync |
| `APC_MEMORY_REPO` / `APC_MEMORY_BRANCH` / `APC_MEMORY_TOKEN` | User memory git sync |
| `PORT` | Server listen port (default `4319`) |

Document a new env var in `README.md` (and `desktop-server/README.md` if it
is server-only) **before** shipping the PR that consumes it.

#### Wire-protocol message kinds

`snake_case` string literals, kept in
`desktop-server/src/protocol.ts` as the Zod discriminated union members.
The Swift mirror (`ios/AnyProvCore/.../Server/Protocol.swift`), the Kotlin
mirror (`android/RoamSocketCore/.../protocol/`), and `docs/protocol.md`
must all change in the same PR. Existing kinds: `agent_message`,
`tool_call`, `tool_result`, `diff`, `user_message`, etc.

#### Swift / Kotlin / TypeScript types

`PascalCase`. Keep them in the file that owns them; lift to a shared
`types` module only when 2+ files need them. Wire-protocol types
(`ClientMessage`, `ServerMessage`, `AIModel`, `ProviderId`, `Endpoint`)
are the canonical examples.

#### URL paths and route names

`kebab-case`. The desktop server exposes a small set of HTTP routes
(`/health`, `/pair`, `/session`, `/files/*`) and a single WebSocket path
(`/session`). New routes follow the same style. Electron's internal IPC
channel names use `snake_case` or `kebab-case` to match the existing
preload bridge; check the neighbors first.

### 6. Things AI agents should NOT do

- Do **not** create or keep `<type>/auto-*` or random-string branches.
  Always use a meaningful `<type>/<kebab-slug>`. Rename before the first
  commit if an auto branch slipped through.
- Do **not** work directly on `main`. Everything goes through a branch + PR.
- Do **not** name a branch `<type>/<UserName>/<thing>` or include an external
  ticket ID. `-pr<N>` is the only allowed numeric suffix.
- Do **not** invent new top-level types (`feature`, `bug`, `task`,
  `improvement`). Stick to the Conventional Commits set in § 1.
- Do **not** use Title Case or trailing periods in branch slugs, commit
  subjects, or PR titles.
- Do **not** mix case styles within the same identifier class
  (e.g. `snake_case.ts` next to `kebab-case.ts`).
- Do **not** open a PR whose title doesn't match the commit subject it
  summarizes.
- Do **not** ship a one-sided protocol change. The TS schema, Swift
  Codable, Kotlin mirror, and `docs/protocol.md` must all change together.
- Do **not** add a Swift file under `ios/App/Sources` without running
  `npm run xcodegen` and committing the regenerated `.xcodeproj`.
- Do **not** add a "research notes" `.md` at the repo root. Put it under
  `.research/` and link it from `AGENTS.md`.
- Do **not** log a full API key, PAT, or token. Use the redaction helper.
- Do **not** introduce a second theme palette or a non-`#6aa9ff` accent
  without an explicit product decision.

### 7. Quick reference

Walk this list and stop at the first matching rule:

0. **About to create a branch?** → meaningful `<type>/<kebab-slug>`. No
   auto/random names, ever.
1. **Commit?** → `<type>(<scope>): <summary>`, imperative, lowercase, no
   period, ≤ 72 chars.
2. **PR title?** → identical to the commit subject it summarizes.
3. **New file?** → match the neighbors' case, suffix, and test location
   (§ 4). Swift = `PascalCase.swift`, Kotlin = `PascalCase.kt`,
   TypeScript module = `kebab-case.ts`. Test next to the unit.
4. **Env var, protocol kind, type?** → match the closest existing entry
   (§ 5). Document new env vars in `README.md` before shipping.
5. **Protocol change?** → TS schema + Swift Codable + Kotlin mirror +
   `docs/protocol.md` in the same PR.

If none fits and there is real ambiguity, stop and ask — do not invent a
convention.

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
- Auto-named or random-named branch
- PR title doesn't match the commit subject it summarizes

## Questions?

Open an issue or ask in a PR. The repo is actively maintained by
[@roamsocket-ai](https://github.com/roamsocket-ai).
