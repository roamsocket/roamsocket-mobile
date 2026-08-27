# Phase 1 Resumption Notes (Android Projects)

**Date:** 2026-08-27
**Branch:** `feat/android-projects`
**Plan file:** `docs/superpowers/plans/2026-08-27-android-projects-plan.md`
**Ledger:** `.superpowers/sdd/2026-08-27-android-projects-plan/progress.md`

## Where we are

Tasks 1–10 are committed. The data layer (ProjectItem, ProjectChatItem,
MemoryCommandParser, ProjectRepository interface, InMemoryProjectRepository
with 26 tests, DataStoreProjectRepository with Robolectric test) and
integration wiring (AppContainer, ChatHistoryStore coordinator,
ChatTitleGenerator) are all done and reviewed. The compile is clean and
the full RoamSocketCore suite is at 103/103.

**Tasks still to do:** 11 (ChatViewModel), 12 (Projects list + create + nav),
13 (Project detail + Instruction + Memory sheets), 14 (AddToChatSheet real
project picker), 15 (final verification + PR).

## How to resume

From the worktree root:

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git status   # should be clean
git log --oneline -5
```

Read the plan file's Tasks 11–15 sections (sections 800+ in the plan file)
for the exact code to write — the briefs are exhaustive and the
implementer (subagent or you) should follow them verbatim. Each task
ends with a `git commit` line — use those commit messages.

## What's been validated

- **JDK 17 auto-provisions** via foojay-resolver-convention (added to
  `settings.gradle.kts`). The hardcoded Windows path in
  `gradle.properties` was removed because its space broke URI parsing
  on macOS.
- **`local.properties`** is now present with
  `sdk.dir=/Users/jc/Library/Android/sdk`. This is gitignored.
- **Test counts:** 103/103 in `:RoamSocketCore:test`; 2/2 in
  `DataStoreProjectRepositoryTest`. The pre-existing
  `DataStoreChatHistoryRepositoryTest` is flaky on Robolectric cold
  start (50ms delay too short) — not related to Phase 1.

## What to watch for (lessons from in-flight Task 11 work)

The subagent started Task 11 (ChatViewModel integration) and made good
progress before the user asked to pause. I reverted the in-flight
changes. Key gotchas to remember when picking it back up:

1. **ChatViewModel private state names:** the plan says "whatever naming
   the existing code uses" — check the file first. Look for
   `_messages`, `_state`, `_activeChatId`, `_selectedModel`,
   `_selectedProvider`, `_selectedModelName` (or similar). The
   implementer for Task 11 found the state lives on
   `ChatUiState.value` (a single `MutableStateFlow<ChatUiState>`)
   rather than separate per-field flows. Read
   `android/app/src/main/kotlin/app/roamsocket/android/ui/chat/ChatViewModel.kt`
   carefully before writing the project-aware additions.

2. **The ChatUiState pattern:** the existing `ChatUiState` is a
   data class with `messages: List<UiMessage>` and friends. Loading
   a project chat will need to update this state — the
   `loadProjectChat` method must use the same `toUi` /
   `_state.update { it.copy(messages = ...) }` pattern the existing
   `init()` uses for global chat load.

3. **`persistMessages` routing:** the existing `saveMessages` /
   `saveMessagesBatch` (or whatever they're called) is the call site
   for message persistence. Wrap it in a new `persistCurrent(messages)`
   that checks `historyStore.activeProject.value` and routes to
   `projectRepository.saveProjectChatMessages` or the global path
   accordingly. Don't break the existing call sites.

4. **`openProjectChatAsActive`** sets the project's
   `activeProjectId` AND pins the chat id on the chat-history
   repository's `activeChatId` (so existing code can find "the active
   chat"). This is implemented in `ChatHistoryStore` (Task 9) but
   requires that the chat view-model treats the global
   `activeChatId` setter as a way to "focus on" a project chat too.

## Task 11 — ChatViewModel integration

Files to modify:
- `android/app/src/main/kotlin/app/roamsocket/android/ui/chat/ChatViewModel.kt`

New code (per plan):

```kotlin
import app.roamsocket.android.ui.sidebar.ChatHistoryStore
import app.roamsocket.core.projects.ProjectChatItem
import app.roamsocket.core.projects.ProjectItem
import app.roamsocket.core.providers.AIModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

class ChatViewModel(
    // ... existing constructor args ...
) {
    // ... existing fields ...

    /** Currently-active project (resolved from [ChatHistoryStore.activeProject]). */
    val activeProject: StateFlow<ProjectItem?> = historyStore.activeProject

    /** Display name of the active project, or null for the global Recents list. */
    val currentProjectName: StateFlow<String?> = activeProject
        .map { it?.name }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    fun loadProjectChat(project: ProjectItem, chat: ProjectChatItem) {
        historyStore.openProjectChatAsActive(project.id, chat.id)
        val messages = historyStore.projectChatMessages(project.id, chat.id)
        // Reuse the same toUi / state-update path the existing init() uses
        // for global chat hydration. Clear incognito flags because project
        // chats are never incognito.
        _state.update { it.copy(messages = messages.map(::toUi), /* ... */) }
        val savedModel = historyStore.projectChatSelectedModel(project.id, chat.id)
        if (savedModel != null) {
            _state.update { it.copy(/* model fields from savedModel */) }
        }
    }

    fun attachCurrentChatToProject(project: ProjectItem) {
        val id = _state.value.activeChatId ?: return
        historyStore.addChatToProject(id, project.id)
    }

    fun renameActiveProjectChat(newTitle: String) {
        val project = historyStore.activeProject.value ?: return
        val id = _state.value.activeChatId ?: return
        historyStore.renameProjectChat(project.id, id, newTitle)
    }

    fun deleteActiveProjectChat() {
        val project = historyStore.activeProject.value ?: return
        val id = _state.value.activeChatId ?: return
        historyStore.deleteProjectChat(project.id, id)
    }
}
```

The `persistMessages` / `saveMessagesBatch` (or whatever) method needs
to be wrapped:

```kotlin
private fun persistCurrent(messages: List<PersistedChatMessage>) {
    val activeProject = historyStore.activeProject.value
    val chatId = _state.value.activeChatId ?: return
    if (activeProject != null) {
        historyStore.saveProjectChatMessages(activeProject.id, chatId, messages)
    } else {
        historyStore.saveMessages(chatId, messages)
    }
}
```

Replace all existing call sites that wrote to `historyStore.saveMessages(...)`
with `persistCurrent(...)`.

After implementing, run `./gradlew :app:compileDebugKotlin` to verify
(no new warnings). The plan does not require a JVM test for this task;
the test surface lives in Task 15's full-suite verification.

Commit message: `feat(android): ChatViewModel loads/saves project chats`.

## Task 12 — UI: Projects list + create + navigation

Files to create:
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsViewModel.kt`
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/CreateProjectSheet.kt`
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsListScreen.kt`

Files to modify:
- `android/app/src/main/kotlin/app/roamsocket/android/ui/RootView.kt` (wire destinations)

The plan has the full code for each file. Critical bits to remember:
- `ProjectsViewModel` is a thin wrapper around `ChatHistoryStore` that
  exposes the `projects` flow and `createProject` method. Use
  `LocalAppContainer` + `rememberChatHistoryStore()` to construct.
- `CreateProjectSheet` is a simple `AlertDialog` with name + optional
  description fields.
- `ProjectsListScreen` uses `Scaffold` with `TopAppBar` + `FloatingActionButton`
  + `OutlinedTextField` (search) + `LazyColumn` of `Surface` rows. Use
  existing `MaterialTheme.colorScheme` tokens. Pattern matches
  the `ArtifactsListScreen` and `StudyScreen` in the same repo.
- The empty state should mirror the iOS `ContentUnavailableView` —
  centered icon + title + subtitle in a `Column`.
- The relative time formatter is a local helper (`relativeTime`); copy
  the one from `ProjectDetailScreen` if needed.
- `RootView` needs a new `projectsSubDest` state (sealed class with
  `List` and `Detail(projectId)` cases), reset in `navigate()` like
  the other sub-dests. Wire `SidebarDestination.Projects` to it.

Commit message: `feat(android): add Projects list + create sheet + sidebar wiring`.

**Note:** the plan's `ProjectDetailScreen.kt` reference in `RootView`
will fail to compile until Task 13 lands. To unblock intermediate
builds, you can temporarily add a `PlaceholderScreen` stub in
`android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectDetailScreen.kt`
and replace it in Task 13. Or, do Task 13 immediately after Task 12
in a single batched commit.

## Task 13 — UI: Project detail + Instruction + Memory sheets

Files to create:
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectDetailScreen.kt`
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectInstructionsSheet.kt`
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectMemorySheet.kt`

Files to modify:
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsViewModel.kt`
  (add `loadProject(id): ProjectItem?`)

The plan has the full code. Critical bits:
- `ProjectDetailScreen` takes `(projectId: String, onBack: () -> Unit,
  onOpenChat: () -> Unit)`. It renders the instruction pill, memory
  banner, and chats list.
- For "New chat" and tapping a project chat row: call
  `viewModel.historyStore.setActiveProject(project.id)` +
  `viewModel.historyStore.openProjectChatAsActive(project.id, chat.id)`
  (already implemented in Task 9), then `onOpenChat()` which navigates
  to `SidebarDestination.Chats`. The `ChatViewModel` (Task 11) hydrates
  the chat from the project store.
- The instruction pill and memory banner are `Surface` rows with
  `clickable` lambdas that open the respective sheets.
- The chats list is a `LazyColumn` of `ProjectChatRow` (private helper).
  Each row has edit (rename) and delete icons. Edit opens an
  `InlineRenameDialog`; delete shows a confirm `AlertDialog`.
- `ProjectInstructionsSheet` is a `ModalBottomSheet` with an
  `OutlinedTextField` (180.dp tall) and Save/Cancel buttons. Calls
  `viewModel.historyStore.updateProjectInstructions(...)` on save.
- `ProjectMemorySheet` is a `ModalBottomSheet` with two `OutlinedTextField`s
  (memory text + command field). The command field has a submit
  `IconButton` (arrow-forward) that calls
  `viewModel.historyStore.applyProjectMemoryCommand(project.id, cmd)`,
  which updates the memory text inline. Save button calls
  `updateProjectMemory`. Cancel dismisses.

Commit message: `feat(android): add ProjectDetailScreen + Instructions + Memory sheets`.

## Task 14 — UI: AddToChatSheet real project picker

Files to modify:
- `android/app/src/main/kotlin/app/roamsocket/android/ui/chat/AddToChatSheet.kt`
- `android/app/src/main/kotlin/app/roamsocket/android/ui/chat/ChatScreen.kt`

Critical changes:
- The `AddToChatSheet` composable signature gains:
  ```kotlin
  projects: List<ProjectItem>,
  currentProject: ProjectItem?,
  onPickProject: (ProjectItem) -> Unit,
  onCreateProjectAndAttach: (name: String) -> Unit,
  ```
  (in addition to the existing `onAddToProject: () -> Unit` which gets
  removed).
- Inside the sheet, the "Add to project" row is now an inline picker:
  - If `projects` is empty, show "No projects yet — create one"
  - Else, show an expandable list of project names
  - Tapping a project name calls `onPickProject(project)` and dismisses
  - "New project…" reveals a small text field + Create/Cancel;
    on Create, calls `onCreateProjectAndAttach(name)`
- The current project's name shows on the row trailing position
  (matches iOS `viewModel.currentProject ?? "None"`).
- In `ChatScreen`, replace the existing
  `onAddToProject = { navigateToSidebar(...) }` with:
  ```kotlin
  val projects by rememberProjectsViewModel().projects.collectAsState()
  val activeProject by viewModel.activeProject.collectAsState()
  onPickProject = { project ->
      viewModel.attachCurrentChatToProject(project)
      showAddToChat = false
  },
  onCreateProjectAndAttach = { name ->
      val newProject = historyStore.createProject(name)
      viewModel.attachCurrentChatToProject(newProject)
      showAddToChat = false
  },
  ```
  Add imports for `rememberProjectsViewModel` and `ProjectItem`.

Commit message: `feat(android): replace AddToChat 'Add to project' with real picker`.

## Task 15 — Final verification + PR

The plan's Step 1–6 are the verification flow. Key things:

1. Run `./gradlew :RoamSocketCore:test` — expect 103 pre-existing +
   new project tests (data layer). All green.
2. Run `./gradlew :app:testDebugUnitTest` — expect DataStore tests to
   pass; the pre-existing `DataStoreChatHistoryRepositoryTest` flake
   may need its delay bumped (50→200ms) — that's an environment
   issue, not a Phase 1 bug, but you can fix it for hygiene.
3. Run `./gradlew assembleDebug` — expect clean build.
4. Manual smoke on a device or emulator (fresh install recommended):
   - Open sidebar → Projects → no PlaceholderScreen
   - Create a project → see it in the list
   - Open project → see Instructions pill + Memory banner
   - Edit Instructions (save) → pill updates
   - Edit Memory: "remember I like coffee" → bullet appears
   - "forget coffee" → bullet removed
   - "New chat" inside project → blank project chat created
   - From a global chat: + → "Add to project" → pick project → chat
     appears in the project's chats list
   - In the project detail: rename a chat → name updates; delete →
     confirmation dialog → confirm → chat disappears
   - Kill app, relaunch → all state persists
5. `git push -u origin feat/android-projects`
6. `gh pr create` with the body from the plan.

If any step fails, file it as a follow-up in the PR description; do
not block the PR on cosmetic issues.

## Decision shortcuts

If you want to skip the per-task subagent round-trip when resuming,
it's safe to do Tasks 11–14 directly in this session (or your next
session) — the briefs in the plan file are exhaustive and the
implementation is mechanical transcription of typed-out code. The
data layer (Tasks 1–7) and the integration (Tasks 8–10) used both
modes successfully. The subagent catches drift on integration tasks
(Task 11 in particular); the UI tasks (12–14) are pure Compose
transcription and benefit less from review.

## Open follow-ups (not blocking Phase 1 merge)

These are real iOS behaviors we are NOT porting in Phase 1. They
become separate phases or follow-ups:

- `deleteProject` (iOS doesn't have it either; if you want it, add as
  a settings/UI affordance in a later phase)
- Project chat `moveToRecents` (iOS has it; useful for "extract"
  flows)
- On-device LLM title generation for project chats (Android uses the
  linked lightweight model via `LightweightTaskRunner` instead)
- Project chat `on-device` heuristic auto-refresh (iOS runs every 3
  user messages)
- Project chat swipe actions in a future sidebar refresh

The "SelectedModel field" divergence is also real: the existing
`ChatHistoryItem` uses `(selectedProvider, selectedModel)` strings,
while the new `ProjectChatItem` uses `selectedModel: AIModel?`. A
follow-up phase should normalize `ChatHistoryItem` to also use
`AIModel?`. Not blocking Phase 1; the codepath in
`addChatToProject` reconstructs `AIModel` from the two strings
best-effort and falls back to `null` if the provider id can't be
resolved.

## Final reminder

When you pick this back up: read the plan file's full task text for
the task you're resuming (each task has the exact file paths, code,
and commit message). The plan file is the single source of truth —
the resumption notes here are just a quick orientation.
