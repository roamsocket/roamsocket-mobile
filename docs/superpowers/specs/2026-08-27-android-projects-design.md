# Phase 1 — Android Projects Port (iOS parity)

**Date:** 2026-08-27
**Status:** Updated per user feedback (lightweight-model-driven chat titles). Awaiting user re-review.
**Parent spec:** `2026-08-27-android-parity-sweep-design.md`
**Branch:** `feat/android-projects` (off `main`)

## Goal

Port the iOS **Projects** feature to Android with full functional parity. A
project is a named container with private instructions, a private memory
field, and its own list of chats. Chats can be created inside a project, or
copied from the global Recents into a project (incognito chats are never
copied). Project memory supports natural-language commands
(`forget X`, `remember that X`, freeform bullets).

## Scope

In scope:

- New `RoamSocketCore/projects/` package (data layer)
- New `app/data/DataStoreProjectRepository.kt` (persistence)
- 5 new Compose screens under `app/ui/projects/`
- Update `ChatHistoryStore` (app-level coordinator) to wire both repositories
- Update `ChatViewModel` to load/save project chats when an active project is in scope
- Update `AddToChatSheet` so "Add to project" is a real picker with new-project flow
- Update `RootView` so `SidebarDestination.Projects` and `SidebarDestination.Project(id)` are real screens
- Update `SidebarView` (sidebar's "Projects" row already navigates; no UI change needed)
- JVM unit tests in `RoamSocketCore` for the data layer

Explicitly out of scope (iOS behaviors not ported, called out in iOS comments):

- **`deleteProject`** — iOS has no project deletion; the Android port matches. Projects are created; their content can be edited (instructions, memory, chats). To "remove" a project, the user can clear its instructions and memory to empty and let the project sit. (If we discover a real need we can add it later; matching iOS first.)
- **Project chat `moveToRecents`** — iOS has it; not ported in Phase 1. Phase 1 keeps project chats inside the project only.
- **On-device LLM title generation for project chats** — covered in Phase 1 via the new `ChatTitleGenerator` that uses `LightweightTaskRunner` (user's linked model). iOS also has an on-device Foundation Model path; Android does not (no Foundation Model equivalent). The user explicitly approved using the linked lightweight model in place of the local model for chat naming.

## Architecture

```
┌─ RoamSocketCore (pure Kotlin, no Android) ────────────────────┐
│  projects/ProjectItem.kt            (kotlinx.serialization)   │
│  projects/ProjectChatItem.kt                                   │
│  projects/ProjectRepository.kt      (interface)                │
│  projects/InMemoryProjectRepository.kt                        │
│  projects/MemoryCommandParser.kt     (forget/remember/freeform)│
└────────────────────────────────────────────────────────────────┘
                          ▲
                          │ implemented by
                          │
┌─ app/data/ (Android DataStore) ──────────────────────────────┐
│  DataStoreProjectRepository.kt                                │
│    • wraps InMemoryProjectRepository                           │
│    • JSON-blob persistence to DataStore (one key)             │
│    • loaded once at app start                                  │
└────────────────────────────────────────────────────────────────┘
                          ▲
                          │ injected via AppContainer
                          │
┌─ app/ui/ (Compose) ───────────────────────────────────────────┐
│  ChatHistoryStore.kt   — app-level coordinator                │
│    • owns both ChatHistoryRepository + ProjectRepository       │
│    • exposes Compose-friendly StateFlows and command helpers   │
│                                                                 │
│  ChatViewModel.kt       — load/save project chats              │
│  AddToChatSheet.kt      — real project picker                  │
│  RootView.kt            — wire destinations                    │
│                                                                 │
│  ui/projects/                                                     │
│    ProjectsListScreen.kt                                          │
│    ProjectDetailScreen.kt                                         │
│    CreateProjectSheet.kt                                          │
│    ProjectInstructionsSheet.kt                                    │
│    ProjectMemorySheet.kt                                          │
└────────────────────────────────────────────────────────────────┘
```

**Why split Core into two repos:** each interface has one purpose; tests
can exercise projects in isolation; the app-level `ChatHistoryStore`
matches the iOS `ChatHistoryStore` role of being the coordinator.

**Why JSON blob in DataStore:** matches iOS's single-blob UserDefaults
strategy exactly, so we can byte-compare mental models and the same key
shape in any future cross-platform migration tool.

## Data model (1:1 with iOS)

```kotlin
@Serializable
data class ProjectItem(
    val id: String,                  // UUID string
    val name: String,
    val updatedAtMillis: Long,
    val instructions: String = "",
    val memory: String = "",
    val memoryUpdatedAtMillis: Long? = null,
)

@Serializable
data class ProjectChatItem(
    val id: String,                  // UUID string
    val title: String,
    val lastMessageAtMillis: Long,
    val messages: List<PersistedChatMessage> = emptyList(),
    val isArchived: Boolean = false,
    val selectedModel: AIModel? = null,    // see note below
    val titleIsUserEdited: Boolean = false,
    val didAutoTitle: Boolean = false,
    val autoTitleAtUserCount: Int = 0,
)
```

These match the iOS `ProjectItem` / `ProjectChatItem` shape 1:1, including
default values and the JSON key names. `id` is stored as a `String`
(Android UUID → stringified) so it can be a `Map<String, _>` key without
custom serializers — same as the existing `ChatHistoryItem.id` pattern.

**Note on `selectedModel`:** iOS stores an `AIModel?` object on the
project chat; the Android side already has
`app.roamsocket.core.providers.AIModel` (kotlinx-serializable, mirrors
iOS `AIModel.swift`). For 1:1 parity, `ProjectChatItem.selectedModel`
is `AIModel?` — not the `(provider, modelID)` string split used on the
existing `ChatHistoryItem`. The two will be normalized in a future
phase; the project port matches iOS first.

## ProjectRepository interface (mirrors iOS ChatHistoryStore)

```kotlin
interface ProjectRepository {
    val projects: StateFlow<List<ProjectItem>>
    val projectChats: StateFlow<Map<String, List<ProjectChatItem>>>
    val activeProjectId: StateFlow<String?>

    fun createProject(name: String = "New project"): ProjectItem
    fun updateProjectInstructions(projectID: String, instructions: String)
    fun updateProjectMemory(projectID: String, memory: String)
    fun applyProjectMemoryCommand(projectID: String, command: String): String

    fun addChatToProject(source: ChatHistoryItem, projectID: String): ProjectChatItem?
```

**Note on `addChatToProject`:** the existing `ChatHistoryItem` exposes
`selectedProvider`/`selectedModel` as separate strings. When copying
into a `ProjectChatItem.selectedModel: AIModel?`, we reconstruct the
`AIModel` from those strings (best-effort; falls back to `null` if the
provider id can't be resolved). This is the only place the two
representations meet; documented in the function kdoc.
    fun renameProjectChat(projectID: String, chatID: String, title: String)
    fun deleteProjectChat(projectID: String, chatID: String)
    fun archiveProjectChat(projectID: String, chatID: String)

    fun startNewChatInProject(projectID: String, selectedModel: AIModel? = null): ProjectChatItem
    fun saveProjectChatMessages(projectID: String, chatID: String, messages: List<PersistedChatMessage>)
    fun projectChatMessages(projectID: String, chatID: String): List<PersistedChatMessage>
    fun projectChatSelectedModel(projectID: String, chatID: String): AIModel?
    fun saveProjectChatSelectedModel(projectID: String, chatID: String, model: AIModel)

    fun setActiveProject(projectID: String?)
    fun pruneBlankProjectDrafts()
    fun replaceAll(projects: List<ProjectItem>, projectChats: Map<String, List<ProjectChatItem>>, activeProjectId: String?)
    fun snapshot(): ProjectsStateSnapshot
}

data class ProjectsStateSnapshot(
    val projects: List<ProjectItem>,
    val projectChats: Map<String, List<ProjectChatItem>>,
    val activeProjectId: String?,
)
```

`addChatToProject` takes a `ChatHistoryItem` (not a chatID) because
copying needs the full record (title, messages, model). This deviates
slightly from the iOS signature (`addChatToProject(chatID:projectID:)`)
but only in the entry point — the iOS store internally re-fetches the
chat from `recents` to build the `ProjectChatItem`; passing the resolved
item up front avoids a redundant lookup and keeps the receiver's job
pure. Documented in the kdoc; matches semantics.

## InMemoryProjectRepository

Mutations always go through a `mutate {}` helper that updates the
private `MutableStateFlow`s and re-publishes derived collections. Same
pattern as `InMemoryChatHistoryRepository`.

Edge cases to mirror iOS:
- `createProject` inserts at index 0; `projectChats[new.id] = []`
- `updateProjectInstructions/Memory` updates `updatedAt` to `now`
- `addChatToProject` returns null when source is incognito, when the
  source doesn't exist, or when the project doesn't exist
- `renameProjectChat` trims, no-ops on empty, sets `titleIsUserEdited`
  and `didAutoTitle`, cancels any pending title task (no title tasks
  yet on Android — stub out as no-op)
- `deleteProjectChat` no-ops when chatID isn't in the project's list
- `archiveProjectChat` sets `isArchived = true`, clears
  `activeProjectId` if the archived chat was active
- `startNewChatInProject` removes any blank draft in that project
  first, inserts a new `ProjectChatItem` at index 0, sets
  `activeProjectId` to the project, sets `activeChatId` to the new
  chat (on `ChatHistoryRepository` via a callback)
- `saveProjectChatMessages` updates messages, `lastMessageAtMillis`,
  runs the heuristic title-derivation (reuse
  `InMemoryChatHistoryRepository.derivedTitle`)
- `pruneBlankProjectDrafts` removes any `ProjectChatItem` whose
  `messages` is empty; clears `activeChatId` if it pointed at one
  (only if that chat is also not in the global recents)

## DataStoreProjectRepository

Mirrors `DataStoreChatHistoryRepository` exactly:

- One DataStore `preferencesDataStore(name = "roamsocket_projects")`
- One preference key `projects_state_json` (single JSON blob)
- Internal `InMemoryProjectRepository` is the source of truth at
  runtime; DataStore mirrors it on every state change
- `replaceAll` is called once at app start to seed the in-memory
  mirror from disk
- Same `Json { ignoreUnknownKeys = true; encodeDefaults = true }`
- Same `flowScope.launch { inMemory.projects.collect { ... } }` pattern
  for persistence

The JSON blob shape (a single object, not three):
```json
{
  "version": 1,
  "projects": [ ... ProjectItem ... ],
  "projectChats": { "<projectId>": [ ... ProjectChatItem ... ] },
  "activeProjectId": "<id or null>"
}
```

`version: 1` lets us migrate later without guessing the field set.
Wraps the actual fields in a typed wrapper (e.g.
`@Serializable data class ProjectState(val version: Int, ...)`).

## MemoryCommandParser (pure function, easy to test)

```kotlin
object MemoryCommandParser {
    /**
     * Apply a natural-language command to an existing memory string.
     *
     * - "forget <topic>"     → strip lines containing topic (case-insensitive);
     *                          if nothing changed, append a "user asked to forget" note.
     * - "remember that I …" / "remember that …" → append a "• Fact." bullet
     * - "remember <fact>"    → append a "• Fact." bullet
     * - anything else        → append as a freeform bullet
     *
     * Each new bullet is prefixed with "• " and joined to the existing
     * memory with "\n\n". Mirrors iOS ChatHistoryStore.applyProjectMemoryCommand.
     */
    fun apply(currentMemory: String, command: String): String
}
```

Pure function — no state, no `ProjectRepository` dependency. Easy to
unit-test in isolation. The repository calls into it from
`applyProjectMemoryCommand`.

## ChatHistoryStore updates (app-level coordinator)

The existing `ChatHistoryStore` in `app/ui/sidebar/` becomes the
coordinator. It already wraps `ChatHistoryRepository`; it gains a
`ProjectRepository` constructor arg and delegates to it.

New methods (1:1 with iOS `ChatHistoryStore`):
- `projects: StateFlow<List<ProjectItem>>` (re-publishes repo flow)
- `projectChats: StateFlow<Map<String, List<ProjectChatItem>>>`
- `activeProject: StateFlow<ProjectItem?>` (derives from
  `activeProjectId` + `projects`)
- `chats(for project: ProjectItem): List<ProjectChatItem>`
- `createProject(name: String): ProjectItem`
- `updateProjectInstructions(projectID: String, instructions: String)`
- `updateProjectMemory(projectID: String, memory: String)`
- `applyProjectMemoryCommand(projectID: String, command: String): String`
- `addChatToProject(chatID: String, projectID: String): ProjectChatItem?`
  (replaces the no-op; resolves chatID via `ChatHistoryRepository`,
  then delegates to `ProjectRepository.addChatToProject`)
- `renameProjectChat(projectID: String, chatID: String, title: String)`
- `deleteProjectChat(projectID: String, chatID: String)`
- `archiveProjectChat(projectID: String, chatID: String)`
- `startNewChatInProject(project: ProjectItem, selectedModel: AIModel?): ProjectChatItem`
- `saveProjectChatMessages(projectID: String, chatID: String, messages: List<PersistedChatMessage>)`
- `projectChatMessages(projectID: String, chatID: String): List<PersistedChatMessage>`
- `setActiveProject(projectID: String?)`
- `pruneBlankProjectDrafts()` — called from app start alongside
  `pruneExpiredIncognito`

`rememberChatHistoryStore()` composable signature gets a new
`projectRepository` arg via `LocalAppContainer`.

## ChatViewModel updates

- New `activeProject: StateFlow<ProjectItem?>` (collected from
  `ChatHistoryStore.activeProject`)
- New `loadProjectChat(project, chat)` that hydrates the chat with
  `messages = ChatHistoryStore.projectChatMessages(...)` and
  `selectedModel = ChatHistoryStore.projectChatSelectedModel(...)`
- New `attachCurrentChatToProject(project)` that calls
  `ChatHistoryStore.addChatToProject(activeChatID, project.id)` and
  toasts / navigates
- `saveMessages(...)` checks if there's an active project; if so,
  writes to `ChatHistoryStore.saveProjectChatMessages(...)`; otherwise
  writes to `ChatHistoryStore.saveMessages(...)` as today
- `addToProject(project)` triggers a confirmation modal with "Add" /
  "Cancel" / "New project…" — last option opens `CreateProjectSheet`
  and then attaches the new project to the current chat
- `currentProjectName: String?` derived state, surfaced in the
  AddToChatSheet so the "Add to project" row can show the current
  project's name (matches iOS `viewModel.currentProject ?? "None"`)

## ChatTitleGenerator (lightweight-model-driven, shared by global + project chats)

Today the Android app derives chat titles heuristically
(`InMemoryChatHistoryRepository.derivedTitle`). For Phase 1 we add a
proper `ChatTitleGenerator` that mirrors the iOS
`Chats/ChatTitleGenerator.swift` and uses the user's linked lightweight
model when one is configured.

**File:** `app/ui/chats/ChatTitleGenerator.kt` (new; co-located with
the other generators).

**Behavior:**

1. If the user has a linked lightweight model in
   `LightweightTasksStore.settings`, call
   `LightweightTaskRunner.complete(container, system, user, maxTokens = 16)`
   with a short system prompt and the chat's first user message.
2. Run the LLM reply through `sanitize(...)` (strip quotes, "Title:"
   prefix, trailing punctuation; cap to 48 chars on a word boundary).
3. If the lightweight model isn't linked, returns null, or the call
   fails, fall back to the existing `derivedTitle(...)` heuristic.
4. Never overwrite a user-edited title.

**Where it's called:**

- `InMemoryChatHistoryRepository.saveMessages(...)` (existing) — keep
  the heuristic as the synchronous interim title; the LLM call is
  fire-and-forget in a `viewModelScope` once we plumb a `container`
  reference.
- `InMemoryProjectRepository.saveProjectChatMessages(...)` (new) —
  same pattern.
- A new `ChatHistoryStore.suggestTitle(chatID)` /
  `suggestProjectTitle(projectID, chatID)` (matches iOS
  `history.suggestTitle(...)` / `suggestTitle(projectID:chatID:)`),
  used by the rename sheet's "Generate" button.

**iOS parity note:** iOS has two title sources — heuristic + on-device
Foundation Model + linked lightweight model. Android has only the
heuristic + linked lightweight model. The LLM path uses the same
`LightweightTaskRunner` that the rest of the app uses for
artifact/commit/thinking-summary generation, so it's already plumbed
through `AppContainer`.

This is the change the user asked for ("if the user has a lightweight
model set in settings it can be tasked to do everything the local model
would do like naming the chats"). It also matches the iOS surface
because both apps route through `LightweightTaskRunner`; only the
default backends differ.

## AddToChatSheet updates

The existing `onAddToProject: () -> Unit` callback gets replaced with
a real in-sheet picker. The flow:

1. User taps "Add to project" row
2. Sheet stays open, a sub-section appears: list of project names
   (or "No projects yet — create one" if empty)
3. Tapping a project name calls `attachCurrentChatToProject(project)`
   and dismisses the sheet
4. Tapping "New project…" opens `CreateProjectSheet`; on confirm,
   creates project, attaches, and dismisses

The current project's name (if any) shows in the row trailing position
(matches iOS `Text(viewModel.currentProject ?? "None")`).

## Navigation wire-up

`RootView.kt` gains a `projectsSubDest` state with three cases:
- `List` — `ProjectsListScreen`
- `Detail(projectId)` — `ProjectDetailScreen(projectId, onBack)`
- `null` — defaults to `List` on entering the destination

Sub-dest resets when the user navigates away from Projects (matches the
existing `studySubDest` and `artifactsSubDest` pattern in `RootView`).

`SidebarDestination.Projects` and `SidebarDestination.Project(id)` lose
their placeholder routing; both go through `projectsSubDest` resolution.

## UI screens (5 new files in `app/ui/projects/`)

| File | Mirrors iOS |
|---|---|
| `ProjectsListScreen.kt` | `Sidebar/ProjectsListView.swift` |
| `ProjectDetailScreen.kt` | `Sidebar/ProjectDetailView.swift` |
| `CreateProjectSheet.kt` | `Sidebar/CreateProjectSheet.swift` |
| `ProjectInstructionsSheet.kt` | `ProjectDetailView.ProjectInstructionsSheet` (inline) |
| `ProjectMemorySheet.kt` | `ProjectDetailView.ProjectMemorySheet` (inline) |

UI patterns to follow (matches recent ports):
- Theme: existing `MaterialTheme.colorScheme` tokens (background,
  surface, onSurface, onSurfaceVariant, primary) — no new colors
- Top app bar: `TopAppBar` with `LocalOpenSidebar` hamburger + back arrow
- Lists: `LazyColumn` with `items()` and clear background
- Empty states: centered icon + title + subtitle (mirrors
  `ContentUnavailableView` on iOS)
- Cards: `Surface(shape = RoundedCornerShape(12.dp), tonalElevation = 1.dp)`
- Search: `OutlinedTextField` with leading search icon (matches iOS search bar)
- FAB: `FloatingActionButton` (or pinned button row, matches iOS
  choice in `ProjectsListView` — pinned button row at the bottom)

iOS's `ChatTitleGenerator` rename sheet (`Chats/RenameChatSheet.swift`)
is reused for project chat rename; if Phase 2 hasn't ported it yet,
the project detail screen will inline a minimal rename modal for
project chats specifically.

## Tests (JVM unit tests in `RoamSocketCore` and `app/`)

`src/test/.../core/projects/`:

1. **`InMemoryProjectRepositoryTest.kt`**
   - createProject inserts at index 0 with new UUID, updatedAt = now
   - createProject initializes empty projectChats[new.id]
   - updateProjectInstructions / updateProjectMemory update fields + updatedAt
   - applyProjectMemoryCommand: forget/remember variants
   - addChatToProject: copies non-incognito, rejects incognito
   - renameProjectChat: trims, no-ops on empty, sets titleIsUserEdited + didAutoTitle
   - deleteProjectChat: removes, no-ops on missing
   - archiveProjectChat: sets flag, clears activeProjectId if matches
   - startNewChatInProject: removes blank draft, inserts at 0, sets active
   - saveProjectChatMessages: updates messages + lastMessageAt
   - projectChatMessages: returns messages for the requested chat
   - setActiveProject: emits on flow
   - pruneBlankProjectDrafts: removes empty project chats

2. **`MemoryCommandParserTest.kt`**
   - forget X strips matching line
   - forget X with no match appends a "user asked to forget" note
   - remember I X appends "• X" bullet
   - remember that X appends "• X" bullet
   - remember X appends "• X" bullet
   - freeform appends "• <input>" bullet
   - empty command returns current memory unchanged

3. **`ProjectRepositoryCodecTest.kt`**
   - JSON round-trip: `InMemoryProjectRepository.snapshot()` →
     `DataStoreProjectRepository` load (via a `TestDataStore`
     helper) → `snapshot()` equal to original
   - Field-name stability: assert the JSON keys match the iOS Codable
     keys (the iOS keys are `id`, `name`, `updatedAtMillis`, etc.)
   - Missing fields decode to defaults (forward-compat)

4. **`DataStoreProjectRepositoryTest.kt`** (uses Robolectric or
   in-memory DataStore) — verify single-blob write/read, version
   handling, and replaceAll hydration.

Test placement matches the existing `core/protocol/`, `core/chats/`,
etc. structure under `RoamSocketCore/src/test/kotlin/app/roamsocket/core/`.

5. **`ChatTitleGeneratorTest.kt`** (Android-side JVM test in `app/src/test/`)
   - sanitize: strips quotes, "Title:" / "Name:" prefix, trailing period
   - sanitize: caps at 48 chars on word boundary, appends "…"
   - sanitize: empty input returns "New chat"
   - suggestTitle: when `LightweightTasksStore.hasLinkedModel == false`,
     returns the heuristic (the "first 6 words" case)
   - suggestTitle: when the LLM call returns a non-blank trimmed string,
     it's used (mock the runner)
   - suggestTitle: when the LLM returns null/blank, falls back to
     heuristic
   - suggestTitle: never overwrites a user-edited title

## Acceptance criteria

Phase 1 is "done" when:

1. `./gradlew :RoamSocketCore:test` passes (all new tests green)
2. `./gradlew assembleDebug` builds clean (no warnings related to the
   new code)
3. From the sidebar, "Projects" is no longer a `PlaceholderScreen`;
   it opens `ProjectsListScreen` with an empty state
4. The user can:
   - Create a project via the FAB → name + create
   - Open the project → see Instructions pill + Memory card + empty
     chat list
   - Edit instructions in the Instructions sheet → save → see them
     reflected on the project
   - Edit memory: type "remember I like coffee" → bullet appears;
     type "forget coffee" → bullet removed
   - Start a new chat inside the project → chat appears in the list
   - Send messages in the project chat → messages persist after
     killing and reopening the app
   - From a global chat: open AddToChatSheet → tap "Add to project"
     → pick a project → the chat now appears in that project's
     detail
   - Rename a project chat via the project detail
   - Delete a project chat
   - The Recents list in the sidebar does NOT include project chats
5. All sidebar destinations work; no `PlaceholderScreen` for
   `Projects` or `Project(id)`
6. `assembleDebug` succeeds; manual smoke from a fresh install creates
   and persists state correctly

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| DataStore JSON blob large for many projects / chats | Match iOS (one blob). If size becomes a problem in practice, split later. |
| Compose-side race when chat-view-model reads `activeProject` flow | Use `combine` with `messages` and `selectedModel` flows; debounce in the view-model. |
| `selectedModel` shape mismatch between `ChatHistoryItem` (two strings) and `ProjectChatItem` (`AIModel?`) | Reconstruct `AIModel` from `ChatHistoryItem` strings in `addChatToProject`; future phase will normalize `ChatHistoryItem` to use `AIModel?`. |
| New 5-screen UI workload | Spec breaks UI into 5 sub-tasks; commits small; PR can split if any screen balloons. |
| Memory command parser edge cases (whitespace, quotes) | Reuse iOS regex `^remember that(?: i)?\s+` and the `forget <topic>` strip; tests cover the common cases. |

## Open follow-ups (not in Phase 1)

These are real iOS behaviors we are explicitly NOT porting in Phase 1
to keep the PR focused. They become separate phases or follow-ups:

- `deleteProject` (iOS doesn't have it either; if the user wants it
  later, add as a settings/UI affordance)
- Project chat `moveToRecents` (iOS has; useful for "extract" flows)
- On-device LLM title generation for project chats
- Project chat `on-device` heuristic auto-refresh (iOS runs every 3
  user messages)
- Project chat swipe actions in a future sidebar refresh
- Foundation Model on-device title generation (iOS-only; Android uses
  the linked lightweight model instead, which Phase 1 wires up)

These get filed as Phase 2+ candidates when Phase 1 merges.
