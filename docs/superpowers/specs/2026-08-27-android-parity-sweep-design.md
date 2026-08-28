# Android iOS-Parity Sweep — Master Design

**Date:** 2026-08-27
**Status:** Awaiting user review (Phase 1 begins after this spec is approved)
**Owner:** mavis (root session)
**Repo:** `roamsocket-mobile` (branch base: `main`)

## Goal

Bring the Android app to feature parity with iOS by porting every iOS-only or
stubbed feature in lockstep, mirroring the iOS data layer 1:1. Deliver as a
sequence of focused PRs (one per phase), each fully implemented, tested at the
data layer, reviewed, and merged before the next phase begins.

## Why now

A parity audit shows Android still stubs or omits roughly 8,000 lines of iOS
behaviour. Recent merges (#93 Artifacts, #94 Environments, #95 Lightweight
Tasks, #97 #98 #99 chat polish + macOS CI) demonstrate the team ships
incremental ports reliably; the user now wants to clear the remaining
backlog in the same style.

## Out of scope

Features that depend on iOS-only runtimes/APIs. They stay iOS-only; the
Android sidebar continues to show a `PlaceholderScreen` for them.

- **LocalMetal / MLX** — on-device LLM runtime, MLX framework is iOS/macOS
- **HealthKit** — Apple health data API, no Android equivalent
- Anything else surfaced during phase implementation that requires an
  iOS-specific framework (e.g. PencilKit, AppIntents)

## Cross-cutting decisions

| Decision | Value | Rationale |
|---|---|---|
| Data layer shape | **1:1 mirror of iOS** (Swift Codable ↔ `kotlinx.serialization`, field names preserved, JSON layout in DataStore mirrors UserDefaults) | Honors `AGENTS.md` protocol-quadruple invariant; makes future cross-port diffs trivial |
| PR cadence | **One PR per phase** | Matches the cadence of recent ports (#93, #94, #95, #99); keeps reviews focused |
| Branching | **One feature branch per phase** off `main` (e.g. `feat/android-projects`) | Mirrors existing branch naming; clean history |
| Tests | **Data layer only** (`RoamSocketCore` JVM tests) | Matches recent PR style; UI verified via `assembleDebug` + manual smoke |
| Theme | **Reuse existing `Theme.kt` tokens** — no new palette | Honors "don't invent a second palette" invariant |
| Wire protocol | **No changes** | Phases 1–7 are UI/UX + storage only |
| Marketplace / docs | **No public docs change** | Behavior is internal; AGENTS.md already notes per-platform feature availability |

## Phases (executed in order)

Each phase has its own design doc under `docs/superpowers/specs/`, its own
implementation plan, and its own PR. Phase 1 begins immediately after this
master spec is approved.

**Ordering rationale:**

- **Phase 1 first** because Projects is the most concrete single feature, has
  the most explicit "TODO" markers on the Android side, and proves the
  1:1 data-mirroring pattern that later phases reuse.
- **Phase 2 next** because chat rename + auto-title touches the same
  `ChatHistoryStore` that Phase 1 just established; doing it back-to-back
  keeps the diff focused.
- **Phases 3–4** consolidate settings and study once chat/org is settled.
- **Phases 5–7** are polish layers (code, voice, skills); they are mostly
  UI and can ship independently once the data layer has stabilised.
- Within each phase, sub-PRs are not planned; one PR per phase is the unit.

| # | Feature | iOS LOC (approx) | Data layer? | Notes |
|---|---|---|---|---|
| 1 | **Projects** (sidebar list/detail, Instructions + Memory, project chats, Add-to-project from chat) | ~1,300 | Yes — `ProjectItem`, `ProjectChatItem`, `ProjectRepository` in `RoamSocketCore/projects/` | Anchor feature; biggest single port |
| 2 | **Chat rename sheet + auto-title** (full) | ~300 | Yes — `ChatTitleGenerator` heuristics + on-device model hook | Polish; sidebar swipe/context menu parity |
| 3 | **Settings gaps** (Marketplace, Default Model, GitHub link, Memory, Settings sync) | ~3,400 | Mostly app-module; small Core additions for marketplace catalog fetch | Settings consolidation |
| 4 | **Study → Classes** (school classes list + detail) | ~850 | Yes — `SchoolClass` + `SchoolClassRepository` in `RoamSocketCore/study/` | Completes Study mode |
| 5 | **Code companion extras** (SSH auto-setup, device connection help) | ~800 | None (UI only) | Code polish |
| 6 | **Voice polish** (settings sheet, TTS providers) | ~1,200 | No new core; app-level services | Completes Voice feature |
| 7 | **Skills/MCP polish** (custom text skill editor, MCP live WebSocket) | ~600 | Yes — `MCPClient` WebSocket in `RoamSocketCore/skills/` | Completes Skills feature |

## Per-phase deliverables

For every phase, the deliverable is:

1. **Spec doc** — `docs/superpowers/specs/YYYY-MM-DD-<phase>-design.md` written before code
2. **Implementation plan** — produced via `writing-plans` skill from the spec
3. **Code** — Kotlin port following the iOS surface 1:1
4. **Tests** — JVM unit tests in `RoamSocketCore` for any new data types / repositories
5. **PR** — one PR per phase, opened when implementation + tests pass + `assembleDebug` succeeds
6. **Verification** — `./gradlew :RoamSocketCore:test` and `./gradlew assembleDebug` clean before opening the PR

## Branch / commit conventions

- Branch name: `feat/android-<phase-slug>` off `main` (e.g. `feat/android-projects`)
- Commit messages: Conventional Commits, full sentences in body, matching recent style
  - e.g. `feat(android): port Projects feature from iOS`
- One feature per PR; squash-merge on approval (matches the repo's current convention)
- No secrets, no build artifacts, no `local.properties` in commits

## Risk register

| Risk | Mitigation |
|---|---|
| Phase 1 (Projects) is large; could overrun | Spec breaks it into 3-4 sub-tasks; commits stay small; PR can split if needed |
| Android Compose patterns differ from SwiftUI | Reuse existing iOS-porting patterns from PRs #93, #94, #95; mirror file/folder structure |
| iOS has iOS-only APIs (e.g. PencilKit) that can't be ported | Mark out-of-scope in the per-phase spec; do not invent Android-only substitutes without explicit user sign-off |
| Data layer 1:1 mirroring may make Kotlin feel unidiomatic | Acceptable trade-off for cross-platform lockstep; document any divergences in the per-phase spec |
| Marketplace catalogs live on an external host we don't control | Reuse the iOS URL parser; do not hardcode any catalog content |

## Phase 1 (Projects) — first sub-spec

Phase 1 will be the first project to go through the full
brainstorm → spec → plan → implement → PR cycle. Its design doc will be
written to `docs/superpowers/specs/2026-08-27-android-projects-design.md`
after this master spec is approved.

The high-level Phase 1 scope (will be detailed in the per-phase spec):

- `RoamSocketCore/projects/` package: `ProjectItem`, `ProjectChatItem`,
  `ProjectRepository` interface, `InMemoryProjectRepository` for
  testing, `DataStoreProjectRepository` (co-located in the app's
  `data/` package alongside `DataStoreChatHistoryRepository`)
- Methods: `createProject`, `updateProjectInstructions`,
  `updateProjectMemory`, `applyProjectMemoryCommand` (forget/remember/freeform),
  `addChatToProject`, `renameProjectChat`, `deleteProjectChat`,
  `archiveProjectChat`, `startNewChat(in: project)`,
  `saveProjectChatMessages`, `projectChatMessages`, `setActiveProject`,
  `pruneBlankProjectDrafts`
- UI: `ProjectsListScreen`, `ProjectDetailScreen`,
  `CreateProjectSheet`, `ProjectInstructionsSheet`, `ProjectMemorySheet`
- Navigation: `SidebarDestination.Projects` and `SidebarDestination.Project(id)`
  become real destinations (not placeholders)
- `AddToChatSheet` "Add to project" entry becomes a real picker with
  new-project + attach-to-current flows
- Chat view-model learns to load/save `ProjectChatItem` when an active
  project is in scope
- Tests: `InMemoryProjectRepository` round-trip + JSON codec + memory
  command parser, matching the iOS `ChatHistoryStore` behaviour

## What gets removed/replaced

- The `PlaceholderScreen` route for `SidebarDestination.Projects` (now real)
- `ChatHistoryStore.addChatToProject` no-op (now wired)
- `AddToChatSheet` → `SidebarDestination.Projects` shortcut (now real picker)
- The `// Projects feature is iOS-only for now` comment
