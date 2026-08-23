# Naming conventions for branches, PRs, commits, files, and identifiers

**Date:** 2026-08-22
**Status:** Draft. Long-form reference. The binding, normative contract is
**[CONTRIBUTING.md § "Naming conventions"](../CONTRIBUTING.md#naming-conventions)**
— when this doc and `CONTRIBUTING.md` disagree, `CONTRIBUTING.md` wins.
**Scope:** every human-driven and AI-agent-driven change to this repo
(iOS app, AnyProvCore, Android app, RoamSocketCore, desktop server, Electron
renderer, marketplace, and the triplicated wire protocol).

This is a **spec, not a config file**. Nothing here is enforced by
`biome.json` or `swiftformat` today; it's a contract AI agents should follow
when naming things, and a reference for humans during code review.

> The strict, short-form contract (and the items agents should *never* do)
> already lives in `CONTRIBUTING.md`. Read that first. This file is the
> long-form companion: more examples, more decision rationale, and a walkable
> decision tree. When the two diverge, file an issue and bump the
> `CONTRIBUTING.md` short-form before relying on the long form.

---

## TL;DR

| Thing | Format | Example |
| --- | --- | --- |
| Branch | `<type>/<kebab-slug>` (or `<type>/<area>/<kebab-slug>` when the change is platform-specific) | `fix/canonical-og-from-route`, `feat/android/code-session` |
| Commit subject | `<type>(<scope>): <summary>` | `fix(seo): derive canonical + og:image from the current route` |
| PR title | Same as the commit subject it summarizes | `feat(ios): add sidebar resume` |
| Worktree dir | `<branch-name-with-slash-replaced-by-dash>` | `.worktrees/chore-naming-conventions-spec/` |
| Swift file (type / view / view model) | `PascalCase.swift` | `RootView.swift`, `ChatViewModel.swift`, `ServerClient.swift` |
| Swift test (XCTest) | `<Unit>Tests.swift` | `ProtocolTests.swift` |
| Kotlin file (class / screen / VM) | `PascalCase.kt` | `MainActivity.kt`, `ChatScreen.kt`, `ServerClient.kt` |
| Kotlin test (JVM) | `<Unit>Test.kt` | `ProtocolRoundtripTest.kt` |
| TypeScript module (server / renderer) | `kebab-case.ts` | `tunnel-clis.ts`, `code-sessions-store.ts`, `chat-turn.ts` |
| TypeScript test | `<unit>.test.ts` next to the unit | `tunnel-clis.test.ts` |
| Root config | lowercase, dotfile or one-word | `vite.config.ts`, `wrangler.jsonc`, `eslint.config.js`, `biome.json` |
| Env var / secret | `SCREAMING_SNAKE_CASE` | `APC_MOCK`, `APC_NAME`, `PORT` |
| Wire-protocol message kind | `snake_case` string literal | `tool_call`, `agent_message`, `diff` |
| Swift / Kotlin / TypeScript type | `PascalCase` | `ClientMessage`, `ServerMessage`, `AIModel` |
| HTTP route / WebSocket path | `kebab-case` (existing routes are single words) | `/health`, `/pair`, `/session`, `/files/*` |

---

## 1. Branch names

### Format

```
<type>/<kebab-slug>
```

or, when the change is platform- or area-specific:

```
<type>/<area>/<kebab-slug>
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

`<area>` is one of `ios`, `android`, `server`, `renderer`, `protocol`,
`theme`, `marketplace`, `deps` (when used as a sub-segment of `chore/deps/...`).
Web is **not** a platform here — never use `web/`.

`<kebab-slug>` is lowercase, dash-separated, ≤ ~40 chars, no trailing dash,
no double dash. Don't use Title Case, dots, or external ticket IDs.

### Suffixes

- `-pr<N>` — append when the branch is the Nth iteration of the same logical
  change (a PR sent back for review and re-pushed). Bump the number instead
  of mutating the slug: `fix/canonical-og-from-route-pr2`.

### Examples already in the repo

```
feat/android/add-to-chat-sheet
feat/android/code-session
feat/android/empty-state-polish
feat/android/image-attachments
feat/android/inline-error
feat/android/markdown-chat-bubbles
feat/android/model-picker-sheet
feat/android/per-chat-model-selection
feat/android/per-model-vision
feat/android/provider-api-keys-sheet
feat/android/remove-launch-api-key-popup
feat/android/repository-picker
feat/android/settings-tab
feat/android/settings-wiring
feat/android/streaming-chat
chore/branch-and-pr-conventions
chore/gradle-jdk17-toolchain-paths
chore/naming-conventions        # the merged #64 short-form contract
fix/android/chat-persist-on-send-failure
integration/android-feature-batch1
integration/android-feature-batch2
merge/pr-45-pr-46
```

### Rules

- **No `main` work directly.** `main` is protected; everything goes through
  a branch + PR.
- **No auto branches. No random-string branches.** Never create or keep a
  `feat/auto-<yyyyMMdd>-<id>` branch (or any opaque / random-string branch).
  Every branch gets a human-readable `<type>/<kebab-slug>` from the start.
  This is **stricter than the StrainEase template** because the existing
  StrainEase allowance has caused enough `feat/auto-20260819-*` clutter in
  this repo — the merged `CONTRIBUTING.md` contract already bans it.
- **No personal names, external ticket IDs, or build numbers in the slug.**
  The `-pr<N>` suffix is the only numeric suffix allowed.
- **Scope goes in the slug when it matters.** Prefer
  `feat/android/<slug>` / `feat/ios/<slug>` / `feat/server/<slug>` over a
  bare `feat/<slug>` whenever the change is platform-specific. For
  cross-cutting work, pick the most affected area
  (`feat/protocol/<slug>`, `feat/renderer/<slug>`, `feat/theme/<slug>`,
  `feat/marketplace/<slug>`).
- **Legacy `feature/` (no `s`) branches exist** on a handful of older
  PRs (`feature/vision-copy-qr`, etc.). Keep those branches; do not
  create new `feature/` branches — use `feat/`.
- **Slash → dash for filesystem paths.** Git worktree directories and
  any non-git filesystem reference (CI artifacts, scratch dirs) drop the
  slash. The worktree for `chore/naming-conventions-spec` lives at
  `.worktrees/chore-naming-conventions-spec/`. See § 4.

### AI agent behavior — never create an auto branch

The Mavis / mavis runtime hands every AI session a worktree on a
placeholder branch named `<type>/auto-YYYYMMDD-<id>`. **This repo bans
that name outright** (see `CONTRIBUTING.md` § "Naming conventions" → "No
auto or random-string branches"). The first thing an AI agent must do on
a new worktree is rename the branch *before the first commit*:

```bash
# from inside the worktree, before the first commit
git branch -m <current-auto-name> <type>/<kebab-slug>
# or, for a platform-scoped change:
git branch -m <current-auto-name> <type>/<area>/<slug>
```

This rule is **unconditional** — every worktree, every session, every
commit, every PR, every agent. Rationale:

- The auto name is opaque in `git log --all`, in the GitHub branch list,
  in the merge commit message, and in code review.
- The repo already has too many `feat/auto-*` legacy branches. We stop
  adding more.
- Renaming locally costs zero work. Not renaming pays off as confusion on
  every downstream surface.
- There is **no "small enough to skip" exception**. A single typo fix is
  still a real change worth a real name. A pure-docs housekeeping commit
  goes on `docs/<slug>`, not on `chore/auto-...`.

When to rename: **before the first commit, before the first push**. Both
orderings are equivalent for this repo, but pre-commit is cheaper to
reason about.

---

## 2. Commit messages

Conventional Commits. Subject line:

```
<type>(<scope>): <summary>
```

- **`<type>`** — same set as branch types, plus `revert` for backouts.
- **`<scope>`** — optional, lowercase, one of:
  `ios`, `android`, `server`, `renderer`, `protocol`, `theme`,
  `marketplace`, `git`, `ci`, `deps`, `docs`, `cli`. Compound scopes are
  allowed with `+`: `feat(ios+android): ...`.
- **`<summary>`** — imperative mood, lowercase first letter, no trailing
  period, ≤ 72 chars. Reference the *what* and *why*, not the diff.
- **Body** (optional) — 1–3 sentences explaining the *why* for protocol,
  security, theme, or shared-infra changes.
- **Footer** — use a `BREAKING CHANGE: <one-liner>` footer for any
  public-API change: a wire-protocol field rename, an env-var rename, a
  Swift public-API change consumed by another module.

### Examples from the merged history (post-`#64`)

```
fix(seo): derive canonical + og:image from the current route
fix(server): use credential helper for ops.ts pulls (auth parity with github.ts)
feat(protocol): add agent task checklist and desktop Metal listing
style(renderer): tighten chat composer spacing and hover states
chore(deps): bump react and react-dom to 19.2.7
docs: remove Convex references from README and integrations.md
```

Pre-`#64` commit subjects in this repo are still in the older
`<Scope>: <Imperative description>` Title-Case format
(e.g. `Android: Chat MVP — providers, encrypted key store, model picker,
chat screen`). Don't pattern-match against those — they're a transition
artifact and the `#64` short-form contract supersedes them.

### Notes

- `style(renderer)` / `style(theme)` is the prefix for visual-only
  changes (spacing, colors, copy polish). Reserve `fix` for actual
  broken behavior.
- One commit per logical change. Squash `wip` / `fix typo` / `amend pr-N`
  commits before opening a PR (or before pushing the `-pr2` round).
- Don't use the branch type as the commit type. A `fix/*` branch can
  have `feat` commits if the fix also adds a small capability. Types
  describe the *commit*, not the *branch*.

---

## 3. PR titles

**Same format as the commit subject: `<type>(<scope>): <summary>`.**
The repo's history shows the PR title mirrors the subject of the
squashed/merged commit. One PR = one logical change (squash-merge
friendly).

- If the PR spans multiple commits, the title summarizes the *headline*
  change. Don't enumerate sub-changes in the title — that's what the
  PR description is for.
- Title-only (no body) is acceptable for trivial PRs; non-trivial PRs
  must fill in the `.github/pull_request_template.md` (summary, areas
  touched, verification commands, protocol-change diff if any).
- Use the `feat(*)` type even if the underlying branch is `fix/*` when
  the *net* change is a new capability. Match the title to the *change*,
  not the *branch*.
- If the PR is a `-pr2` follow-up, the title stays the same; the body
  carries the iteration note.

---

## 4. Worktree directories

```
.worktrees/<branch-name-with-slash-replaced-by-dash>
```

Examples (already in use):

```
.worktrees/feat-android-add-to-chat-sheet/
.worktrees/feat-android-empty-state-polish/
.worktrees/feat-android-image-attachments/
.worktrees/feat-auto-20260821-e6e7cb61/   # legacy: was renamed to chore/naming-conventions mid-PR
.worktrees/chore-naming-conventions-spec/   # this branch
```

AI agents that create a worktree must name the directory with `-` instead
of `/`. Don't embed extra metadata (no timestamps, no usernames); the
branch already has it.

---

## 5. File and module names

Match the neighbors. The repo has four language surfaces plus shared
configs; each has its own convention.

### 5.1 Swift (iOS app + AnyProvCore)

| Kind | Format | Example | Notes |
| --- | --- | --- | --- |
| UI view | `PascalCase.swift` | `RootView.swift`, `ChatView.swift`, `AddToChatSheet.swift` | One default (or only) public type per file. |
| View model / store | `PascalCase.swift` | `ChatViewModel.swift`, `BrowserStore.swift`, `VoiceSettingsStore.swift` | Same — filename matches the primary type. |
| Service / client / manager | `PascalCase.swift` | `ServerClient.swift`, `GitHubClient.swift`, `SkillManager.swift` | |
| Provider implementation | `PascalCase.swift` | `AnthropicProvider.swift`, `AppleFoundationProvider.swift`, `LocalMetalProvider.swift` | One provider per file. |
| Model / value type | `PascalCase.swift` | `AIModel.swift`, `MarketplaceModels.swift`, `BrowserModels.swift` | Sub-types used only by the parent can live in the same file (`MarketplaceModels.swift` can declare both `MarketplaceEntry` and a parsing helper). |
| Wire-protocol types | `Protocol.swift` (in `Server/`) | `ios/AnyProvCore/.../Server/Protocol.swift` | One file, mirrors `desktop-server/src/protocol.ts`. |
| Capability / detector | `PascalCase.swift` | `VisionCapability.swift` | |
| Feature folder | `PascalCase` | `Features/Chat/`, `Features/Skills/`, `Features/Code/`, `Features/Sidebar/`, `Features/Settings/` | |
| DesignSystem | `Theme.swift`, shared components | `DesignSystem/Theme.swift` | |
| Test (XCTest) | `<Unit>Tests.swift` | `ProtocolTests.swift` | Lives next to the unit when possible, in a `Tests/` folder otherwise (e.g. `ios/AnyProvCore/Tests/AnyProvCoreTests/`). |

**Forbidden**

- No Swift `index.swift` re-export barrels inside `Features/` or
  `AnyProvCore/...` subdirectories. Import the module directly.
- No `Card` inside `Card` in SwiftUI — that's a UI rule from `AGENTS.md`,
  not a naming rule, but it constrains component split names: prefer
  `*Section` / `*Panel` / `*Header` over a `*Card` containing a `*Card`.

### 5.2 Kotlin (Android app + RoamSocketCore)

| Kind | Format | Example | Notes |
| --- | --- | --- | --- |
| Application / activity | `PascalCase.kt` | `RoamSocketApplication.kt`, `MainActivity.kt` | |
| View / screen | `PascalCase.kt` | `ChatScreen.kt`, `CodeScreen.kt`, `RepositoryPickerSheet.kt` | |
| View model | `PascalCase.kt` | `ChatViewModel.kt`, `SettingsViewModel.kt`, `RepositoryPickerViewModel.kt` | |
| Repository / data source | `PascalCase.kt` | `DataStoreChatHistoryRepository.kt`, `DataStoreCodeSessionRepository.kt` | |
| Service / network client | `PascalCase.kt` | `ServerDiscovery.kt`, `GitHubClient.kt`, `ServerClient.kt` | |
| Encrypted store | `PascalCase.kt` | `EncryptedPrefsSecretStore.kt` | |
| Data class / sealed hierarchy | `PascalCase.kt` | `SessionConfig.kt`, `PersistedChatMessage.kt`, `Pairing.kt` | |
| Wire-protocol types | `Protocol.kt` + per-message files | `RoamSocketCore/.../protocol/Protocol.kt`, `ClientMessage.kt`, `ServerMessage.kt` | Mirrors `desktop-server/src/protocol.ts` and the Swift Codable. |
| Package paths | lowercase, dot-separated | `app.roamsocket.android.ui.chat`, `app.roamsocket.core.protocol` | The path segment after `app.roamsocket.` is a single word, lowercase. |
| Test (JVM) | `<Unit>Test.kt` | `ProtocolRoundtripTest.kt` | Run with `./gradlew :RoamSocketCore:test`. |

**Forbidden**

- No Kotlin re-export files (no `Package.kt` barrels inside `ui/...` or
  `data/...`). Import the file directly.
- No `Wrapper.kt` / `Helper.kt` / `Utils.kt` for class-with-mixed-bag
  patterns. Match the neighbors — if the file holds a repository,
  name it `<Resource>Repository.kt`.

### 5.3 TypeScript (desktop server + Electron renderer)

| Kind | Format | Example | Notes |
| --- | --- | --- | --- |
| Module / lib / util | `kebab-case.ts` | `tunnel-clis.ts`, `code-sessions-store.ts`, `memory-sync.ts` | One primary export per file. |
| Server entry / router | `kebab-case.ts` | `index.ts`, `sessions.ts`, `pairing.ts`, `discovery.ts` | Server root is `index.ts`; area sub-entries follow kebab-case. |
| Agent / tool / git submodule | `kebab-case.ts` | `agent/loop.ts`, `agent/goal.ts`, `tools/bash.ts`, `git/ops.ts` | |
| Electron main / preload | `kebab-case.ts` | `electron/main.ts`, `electron/preload.ts`, `electron/service.ts` | |
| Renderer module | `kebab-case.ts` | `chat-turn.ts`, `chat-stream.ts`, `composer-input.ts`, `project-modals.ts` | |
| Zod schema / type-only module | `kebab-case.ts` | `protocol.ts`, `tools/types.ts` | |
| Test | `<unit>.test.ts` next to the unit | `tunnel-clis.test.ts`, `chat-stream.test.ts` | Run with `npm run test:cli` (CLI parser / TUI reducer / mock local session). |
| HTML / CSS in renderer | lowercase, one word | `renderer/index.html`, `renderer/styles.css` | |
| One-off Node script | `kebab-case.mjs` | `scripts/memory-activity-test.mjs` | |
| `index.ts` re-export barrel | `index.ts` | `desktop-server/src/index.ts` (and the very few area roots that genuinely need one) | **Allowed only at a package root or area root** (e.g. `agent/index.ts`) when it materially helps ergonomics. Forbidden as a thin re-export inside `agent/`, `tools/`, `git/`, `electron/`, `renderer/`. |

**Note on file vs. type casing**

Public types in TypeScript modules are `PascalCase` (`ClientMessage`,
`ServerMessage`, `AIModel`, `ProviderId`, `Endpoint`). The **file** casing
is `kebab-case.ts`. They are different conventions applied at different
layers. Don't move a type into a `PascalCase.ts` file just because the
type is `PascalCase`.

### 5.4 Configs, docs, and root

| Kind | Format | Example | Notes |
| --- | --- | --- | --- |
| Root config | lowercase, dotfile or one-word | `vite.config.ts`, `wrangler.jsonc`, `eslint.config.js`, `biome.json` | Even if the tool is "PascalCase-ish" (e.g. Cloudflare Wrangler), the file on disk is lowercase. |
| Docs (markdown) | `kebab-case.md` | `docs/protocol.md`, `docs/memory-auto-save.md`, `.research/provider-response-quirks.md` | One-word topics are also fine (`docs/protocol.md`). |
| Research notes | `.research/<kebab-case>.md` | `.research/provider-response-quirks.md` | Don't put a `.md` note at the repo root — it disappears. |
| XcodeGen source | `project.yml` (fixed name) | `ios/project.yml` | Generated `.xcodeproj/` is **not** hand-edited. |
| AGENTS / CONTRIBUTING | `AGENTS.md`, `CONTRIBUTING.md` (fixed) | — | Always uppercase, always at the root. |
| Pull request template | `.github/pull_request_template.md` | — | |

---

## 6. Spec / plan / docs filenames

This repo does **not** use the `docs/superpowers/specs/YYYY-MM-DD--<slug>.md`
pattern. The StrainEase template's `docs/superpowers/` tree is a
StrainEase-specific convention and is **not** in scope here. Don't
introduce it.

For RoamSocket:

- **Spec / plan docs** live in `docs/` directly, named `kebab-case.md`
  (e.g. `docs/protocol.md`, `docs/memory-auto-save.md`,
  `docs/naming-conventions.md`).
- **Research notes** live in `.research/<kebab-case>.md` and are linked
  from the `AGENTS.md` research table.
- **No `v1` / `final` / `WIP` suffixes** in filenames. If a doc is a
  draft, say so in its header (`Status: Draft`).
- **When a PR implements a new doc**, reference the doc from the PR
  body so reviewers can find it without grepping.

---

## 7. Identifiers inside code

### 7.1 Env vars / secrets

`SCREAMING_SNAKE_CASE`. The desktop server has one namespace, `APC_*`,
for its own configuration, plus a few standard ones (`PORT`, `HOST`).
There is **no `VITE_*` namespace** here — there is no Vite app in this
repo.

| Var | Meaning |
| --- | --- |
| `APC_MOCK=1` | Run the desktop server with a mock provider (no real API keys) |
| `APC_NAME` | Display name for this server instance |
| `APC_HOST` | Bind address (default `0.0.0.0`) |
| `APC_ADVERTISE=0` | Disable Bonjour / mDNS advertising |
| `APC_AUTO_TUNNEL=0` | Disable the auto-tunnel (Cloudflare quick → ngrok → localtunnel) |
| `APC_BIN_DIR` | Override binary lookup dir for tunnel CLIs |
| `APC_GOAL_EVAL_MODEL` | Override the model used for goal evaluation |
| `APC_GOAL_HEURISTIC=1` | Force the heuristic goal evaluator |
| `APC_SKILLS_REPO` / `APC_SKILLS_BRANCH` / `APC_SKILLS_TOKEN` | User Skills git sync |
| `APC_MCP_REPO` / `APC_MCP_BRANCH` / `APC_MCP_TOKEN` | User MCP git sync |
| `APC_MEMORY_REPO` / `APC_MEMORY_BRANCH` / `APC_MEMORY_TOKEN` | User memory git sync |
| `PORT` | Server listen port (default `4319`) |

**Document a new env var in `README.md`** (and in
`desktop-server/README.md` if it is server-only) **before** shipping the
PR that consumes it. This is a hard rule from `AGENTS.md` (critical
invariants).

### 7.2 Wire-protocol message kinds

`snake_case` string literals, kept in `desktop-server/src/protocol.ts`
as the Zod discriminated union members. The Swift mirror
(`ios/AnyProvCore/.../Server/Protocol.swift`), the Kotlin mirror
(`android/RoamSocketCore/.../protocol/`), and `docs/protocol.md` must all
change in the same PR. Existing kinds include `agent_message`,
`tool_call`, `tool_result`, `diff`, `user_message`, `remote_endpoint`,
`remote_endpoint_request`, etc.

This is the **only** place in the repo where `snake_case` is the
identifier style at the field-name level — it is dictated by the
on-the-wire JSON format. Inside Swift / Kotlin / TypeScript code, the
*property names* on the corresponding Codable / data class / Zod type
mirror the wire form, but the *types themselves* are still
`PascalCase`.

### 7.3 Swift / Kotlin / TypeScript types

`PascalCase`. Keep them in the file that owns them; lift to a shared
`types` module only when 2+ files need them. Wire-protocol types
(`ClientMessage`, `ServerMessage`, `AIModel`, `ProviderId`, `Endpoint`,
`SessionConfig`, `Pairing`) are the canonical examples.

### 7.4 URL paths and route names

`kebab-case` for any multi-segment path. Existing routes are mostly
single words: `/health`, `/pair`, `/session`, `/files/*`, `/metal/models`.
New routes follow the same style — if a new route is multi-segment, the
segments are `kebab-case` (`/agent-tasks`, `/marketplace/list`,
`/sessions/:id/...`).

Electron's internal IPC channel names use `snake_case` or `kebab-case` to
match the existing preload bridge (`ipcRenderer.invoke('show-settings')`
etc.). Check the neighbors before introducing a new channel name.

---

## 8. Things AI agents should NOT do

The strict, normative version of this list is in `CONTRIBUTING.md`.
The list below is the long-form, with rationale.

- **Do not create or keep `<type>/auto-*` or random-string branches.**
  Always use a meaningful `<type>/<kebab-slug>`. Rename before the first
  commit if an auto branch slipped through. **Existing `feat/auto-*`
  branches on `origin` are legacy** — they stay until their PRs land,
  but no new ones.
- **Do not work directly on `main`.** Everything goes through a branch + PR.
- **Do not name a branch `<type>/<UserName>/<thing>` or include an
  external ticket ID.** `-pr<N>` is the only allowed numeric suffix.
- **Do not invent new top-level types** (`feature`, `bug`, `task`,
  `improvement`). Stick to the Conventional Commits set in § 1.
  (`feature/` is legacy-only and not for new work.)
- **Do not use Title Case or trailing periods** in branch slugs, commit
  subjects, or PR titles.
- **Do not mix case styles within the same identifier class** (e.g.
  `snake_case.ts` next to `kebab-case.ts`).
- **Do not open a PR whose title doesn't match the commit subject it
  summarizes.**
- **Do not ship a one-sided protocol change.** The TS schema, the Swift
  Codable, the Kotlin mirror, and `docs/protocol.md` must all change in
  the same PR. See `AGENTS.md` "Critical invariants" § 1.
- **Do not add a Swift file under `ios/App/Sources` without running
  `npm run xcodegen`** and committing the regenerated `.xcodeproj`.
  The PostToolUse hook only catches `project.yml` edits; new Swift
  files need a manual regen.
- **Do not hand-edit `ios/RoamSocket.xcodeproj`.** It's generated. Edit
  `ios/project.yml` and regenerate.
- **Do not add a "research notes" `.md` at the repo root.** Put it under
  `.research/` and link it from the `AGENTS.md` research table.
- **Do not log a full API key, PAT, GitHub token, or pairing token.**
  Use the redaction helper; never `console.log(providerKey)`.
- **Do not introduce a second theme palette or a non-`#6aa9ff` accent**
  without an explicit product decision. Theme tokens live in
  `ios/App/Sources/DesignSystem/Theme.swift`,
  `android/app/.../ui/theme/Color.kt`, and
  `desktop-server/src/renderer/styles.css` (`:root`).
- **Do not break chat-without-server.** Chat must keep working with
  only a provider key. The desktop server is for the Code surface, not
  for Chat.
- **Do not put live catalog JSON in this monorepo's `marketplace/`.**
  That folder is a pointer only. The live catalog lives in
  [roamsocket-ai/roamsocket-marketplace](https://github.com/roamsocket-ai/roamsocket-marketplace).

---

## 9. Quick reference for AI agents

When you need to pick a name, walk this list top to bottom and stop at
the first matching rule:

0. **Are you on an `<type>/auto-YYYYMMDD-<id>` worktree?** → **Stop.
   Rename first.** Run
   `git branch -m <current-auto-name> <type>/<kebab-slug>` from inside
   the worktree, *before the first commit*. See § 1 "AI agent behavior
   — never create an auto branch." The auto name is never a valid
   branch name for a commit or a PR in this repo.
1. **Picking a branch name for non-auto work?** → § 1. Default
   `feat/<area>/<short-description>` or `fix/<area>/<short-description>`
   for platform-specific work, `feat/<area>/<short-description>` for
   area-scoped work, bare `fix/<short-description>` for repo-wide
   fixes. Match the type to the actual change, not the surrounding
   context.
2. **Commit?** → § 2. Subject only, Conventional Commits, scope
   optional, ≤ 72 chars, lowercase, no period.
3. **PR title?** → § 3. Identical to the commit subject it summarizes.
4. **Worktree directory?** → § 4. Replace `/` with `-` in the branch
   name.
5. **New file?** → § 5. Look at the neighbors in the same language.
   Swift = `PascalCase.swift`, Kotlin = `PascalCase.kt`, TypeScript
   module = `kebab-case.ts`. Test next to the unit.
6. **Env var, protocol kind, type, route?** → § 7. Match the existing
   entry closest in shape. Document new env vars in `README.md` before
   shipping.
7. **Protocol change?** → § 7.2 + `AGENTS.md` "Critical invariants" § 1.
   TS schema + Swift Codable + Kotlin mirror + `docs/protocol.md` in
   the same PR.
8. **Picking a doc filename?** → § 6. `docs/<kebab-case>.md` or
   `.research/<kebab-case>.md`. No `docs/superpowers/` — that's a
   StrainEase convention, not in scope here.

If none of the above fits (you've hit a real ambiguity), stop, name the
ambiguity, and ask the user — don't invent a new convention on the fly.

---

## Relationship to other docs

| Doc | Role |
| --- | --- |
| `AGENTS.md` | The correctness / invariants doc. Read first. Wins on conflict. |
| `CONTRIBUTING.md` (especially § "Naming conventions") | The short-form, normative naming contract. Reviewed by humans on every PR. |
| `docs/naming-conventions.md` (this file) | The long-form reference. Examples, rationale, decision tree. Supports the short form. |
| `docs/protocol.md` | The wire-protocol spec. Source of truth for protocol field names referenced in § 7.2. |
| `.research/` | Source-cited research notes referenced by `AGENTS.md`. |
