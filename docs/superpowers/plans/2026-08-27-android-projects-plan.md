# Android Projects (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the iOS Projects feature to Android with full functional parity — sidebar list/detail screens, Instructions + Memory sheets, project-scoped chats, Add-to-project from chat, and lightweight-model-driven chat titles.

**Architecture:** Three-layer split matching recent ports (PRs #93, #94, #95). Pure-Kotlin `ProjectRepository` interface + `InMemoryProjectRepository` + `MemoryCommandParser` live in `RoamSocketCore/projects/`. `DataStoreProjectRepository` (single JSON blob) lives in `app/data/`. `ChatHistoryStore` in `app/ui/sidebar/` becomes the app-level coordinator. New Compose screens live in `app/ui/projects/`. `ChatViewModel` learns to load/save project chats. New `ChatTitleGenerator` uses `LightweightTaskRunner` to name chats (replacing the heuristic-only path).

**Tech Stack:** Kotlin, Jetpack Compose, kotlinx.serialization, kotlinx.coroutines, AndroidX DataStore (Preferences), JUnit 4, kotlinx-coroutines-test, Turbine, MockK, Robolectric (for DataStore tests).

**Spec:** `docs/superpowers/specs/2026-08-27-android-projects-design.md`

## Global Constraints

- **Data layer 1:1 with iOS** — field names, types, and JSON key names must mirror `ios/App/Sources/Features/Chats/ChatHistory.swift`. If iOS uses `updatedAtMillis` as the field name, so do we.
- **Branch:** `feat/android-projects` (already created, off `main`).
- **Commit messages:** Conventional Commits with full sentences, e.g. `feat(android): add ProjectRepository data layer`.
- **Theme:** use `MaterialTheme.colorScheme` tokens already in `ui/theme/`. No new colors, no new palette.
- **No secrets in commits.** No `local.properties`, no `*.jks`, no API keys.
- **No build artifacts in commits** — `android/app/build/`, `.gradle/`, `local.properties` are gitignored; verify with `git status -sb` before committing.
- **Verification commands:**
  - `cd android && ./gradlew :RoamSocketCore:test` — JVM unit tests
  - `cd android && ./gradlew :app:test` — Android JVM + Robolectric tests
  - `cd android && ./gradlew assembleDebug` — must build clean (no new warnings)
- **Conventional PR title for Phase 1:** `feat(android): port Projects feature from iOS`.

---

## File Map

**Created (data layer):**
- `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectItem.kt`
- `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectChatItem.kt`
- `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectRepository.kt`
- `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/InMemoryProjectRepository.kt`
- `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/MemoryCommandParser.kt`
- `android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/ProjectSchemaTest.kt`
- `android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/MemoryCommandParserTest.kt`
- `android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/InMemoryProjectRepositoryTest.kt`

**Created (app data + UI):**
- `android/app/src/main/kotlin/app/roamsocket/android/data/DataStoreProjectRepository.kt`
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsListScreen.kt`
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectDetailScreen.kt`
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/CreateProjectSheet.kt`
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectInstructionsSheet.kt`
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectMemorySheet.kt`
- `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsViewModel.kt` (lightweight VM for the list/detail screens)
- `android/app/src/main/kotlin/app/roamsocket/android/ui/chats/ChatTitleGenerator.kt`
- `android/app/src/test/kotlin/app/roamsocket/android/data/DataStoreProjectRepositoryTest.kt`
- `android/app/src/test/kotlin/app/roamsocket/android/ui/chats/ChatTitleGeneratorTest.kt`

**Modified:**
- `android/app/src/main/kotlin/app/roamsocket/android/AppContainer.kt` — instantiate `DataStoreProjectRepository`; expose to `ChatHistoryStore`.
- `android/app/src/main/kotlin/app/roamsocket/android/ui/sidebar/ChatHistoryStore.kt` — wire `ProjectRepository`; add coordinator methods; remove `addChatToProject` no-op.
- `android/app/src/main/kotlin/app/roamsocket/android/ui/chat/ChatViewModel.kt` — `activeProject`, `loadProjectChat`, `attachCurrentChatToProject`, route `saveMessages` to project or global, `currentProjectName`.
- `android/app/src/main/kotlin/app/roamsocket/android/ui/chat/AddToChatSheet.kt` — replace `onAddToProject: () -> Unit` with an in-sheet project picker.
- `android/app/src/main/kotlin/app/roamsocket/android/ui/RootView.kt` — wire `SidebarDestination.Projects` and `SidebarDestination.Project(id)` to real screens; add `projectsSubDest`.
- `android/app/src/main/kotlin/app/roamsocket/android/ui/artifacts/ArtifactTitleGenerator.kt` — leave as-is (out of scope; Phase 3+).

---

## Task 1: Core data models (ProjectItem, ProjectChatItem)

**Files:**
- Create: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectItem.kt`
- Create: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectChatItem.kt`
- Create: `android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/ProjectSchemaTest.kt`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `ProjectItem` and `ProjectChatItem` `@Serializable` data classes. Field names must match the iOS Codable names in `ios/App/Sources/Features/Chats/ChatHistory.swift` lines 189-225 and 228-289.

- [ ] **Step 1: Create `ProjectItem.kt`**

File: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectItem.kt`

```kotlin
package app.roamsocket.core.projects

import kotlinx.serialization.Serializable

/**
 * A user-created project that groups chats and carries private
 * instructions + memory. Mirrors the iOS `ProjectItem` in
 * `ios/App/Sources/Features/Chats/ChatHistory.swift` 1:1 (field
 * names, types, defaults).
 */
@Serializable
data class ProjectItem(
    val id: String,
    val name: String,
    val updatedAtMillis: Long,
    val instructions: String = "",
    val memory: String = "",
    val memoryUpdatedAtMillis: Long? = null,
)
```

- [ ] **Step 2: Create `ProjectChatItem.kt`**

File: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectChatItem.kt`

```kotlin
package app.roamsocket.core.projects

import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import kotlinx.serialization.Serializable

/**
 * A chat that lives inside a project. Mirrors the iOS
 * `ProjectChatItem` 1:1. `selectedModel` is `AIModel?` to match
 * iOS (the existing `ChatHistoryItem` uses a two-string
 * `(provider, modelID)` split; that is normalized in a later phase).
 */
@Serializable
data class ProjectChatItem(
    val id: String,
    val title: String,
    val lastMessageAtMillis: Long,
    val messages: List<PersistedChatMessage> = emptyList(),
    val isArchived: Boolean = false,
    val selectedModel: AIModel? = null,
    val titleIsUserEdited: Boolean = false,
    val didAutoTitle: Boolean = false,
    val autoTitleAtUserCount: Int = 0,
)
```

- [ ] **Step 3: Write the failing schema test**

File: `android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/ProjectSchemaTest.kt`

```kotlin
package app.roamsocket.core.projects

import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ProviderId
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectSchemaTest {

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        prettyPrint = false
    }

    @Test
    fun projectItemRoundTripsThroughJson() {
        val original = ProjectItem(
            id = "11111111-1111-1111-1111-111111111111",
            name = "RoamSocket Mobile",
            updatedAtMillis = 1_700_000_000_000L,
            instructions = "Think step by step.",
            memory = "• Likes dark mode\n• Prefers concise replies",
            memoryUpdatedAtMillis = 1_700_000_001_000L,
        )
        val encoded = json.encodeToString(original)
        // Spot-check the JSON key names match the iOS Codable shape.
        assertTrue("missing id", encoded.contains("\"id\":\"11111111"))
        assertTrue("missing name", encoded.contains("\"name\":\"RoamSocket Mobile\""))
        assertTrue("missing updatedAtMillis", encoded.contains("\"updatedAtMillis\":1700000000000"))
        assertTrue("missing instructions", encoded.contains("\"instructions\":\"Think step by step.\""))
        assertTrue("missing memory", encoded.contains("\"memory\":\""))
        assertTrue("missing memoryUpdatedAtMillis", encoded.contains("\"memoryUpdatedAtMillis\":1700000001000"))
        val decoded = json.decodeFromString<ProjectItem>(encoded)
        assertEquals(original, decoded)
    }

    @Test
    fun projectItemDefaultsAreAppliedOnDecode() {
        // A JSON body with only the required fields should decode with
        // the documented defaults (empty instructions, empty memory,
        // null memoryUpdatedAtMillis).
        val body = """
            {"id":"abc","name":"X","updatedAtMillis":42}
        """.trimIndent()
        val decoded = json.decodeFromString<ProjectItem>(body)
        assertEquals("", decoded.instructions)
        assertEquals("", decoded.memory)
        assertNull(decoded.memoryUpdatedAtMillis)
    }

    @Test
    fun projectChatItemRoundTripsThroughJson() {
        val original = ProjectChatItem(
            id = "chat-1",
            title = "SSE vs WebSockets",
            lastMessageAtMillis = 1_700_000_000_000L,
            messages = listOf(
                PersistedChatMessage(
                    id = "u-1",
                    role = PersistedChatMessage.Role.USER,
                    content = "What is SSE?",
                    timestampMillis = 1_700_000_000_000L,
                ),
            ),
            isArchived = false,
            selectedModel = AIModel(
                provider = ProviderId.Anthropic,
                modelID = "claude-3-5-sonnet-20241022",
                displayName = "Claude 3.5 Sonnet",
            ),
            titleIsUserEdited = false,
            didAutoTitle = true,
            autoTitleAtUserCount = 1,
        )
        val encoded = json.encodeToString(original)
        assertTrue("missing selectedModel", encoded.contains("\"selectedModel\":"))
        assertTrue("missing modelID", encoded.contains("\"modelID\":\"claude-3-5-sonnet-20241022\""))
        val decoded = json.decodeFromString<ProjectChatItem>(encoded)
        assertEquals(original, decoded)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd android && ./gradlew :RoamSocketCore:test --tests "app.roamsocket.core.projects.ProjectSchemaTest"`
Expected: PASS (3 tests, 0 failures).

- [ ] **Step 5: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectItem.kt \
        android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectChatItem.kt \
        android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/ProjectSchemaTest.kt
git commit -m "feat(android): add ProjectItem and ProjectChatItem data models

Mirror the iOS ProjectItem and ProjectChatItem 1:1 (field names, types,
defaults). ProjectChatItem.selectedModel is AIModel? to match iOS; the
existing ChatHistoryItem two-string split is left for a future cleanup.
Verified via ProjectSchemaTest (round-trip + defaults decode)."
```

---

## Task 2: MemoryCommandParser

**Files:**
- Create: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/MemoryCommandParser.kt`
- Create: `android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/MemoryCommandParserTest.kt`

**Interfaces:**
- Consumes: nothing (the parser is a pure function)
- Produces: `MemoryCommandParser.apply(currentMemory, command): String`

- [ ] **Step 1: Create the parser**

File: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/MemoryCommandParser.kt`

```kotlin
package app.roamsocket.core.projects

/**
 * Pure function for applying natural-language commands to a project's
 * private memory. Mirrors the iOS
 * `ChatHistoryStore.applyProjectMemoryCommand` heuristic:
 *
 * - `"forget <topic>"`     → strip lines containing the topic
 *                            (case-insensitive). If nothing matched,
 *                            append a "user asked to forget" note.
 * - `"remember I <fact>"`,
 *   `"remember that <fact>"`,
 *   `"remember <fact>"`    → append a "• Fact." bullet.
 * - anything else          → append as a freeform bullet.
 *
 * Each new bullet is prefixed with `• ` and joined to the existing
 * memory with `\n\n`. Empty commands return the memory unchanged.
 */
object MemoryCommandParser {

    private val REMEMBER_THAT_REGEX = Regex(
        """^remember that(?: i)?\s+""",
        option = RegexOption.IGNORE_CASE,
    )

    fun apply(currentMemory: String, command: String): String {
        val cmd = command.trim()
        if (cmd.isEmpty()) return currentMemory
        val lower = cmd.lowercase()

        if (lower.startsWith("forget ")) {
            val topic = cmd.drop(7).trim()
                .trim { it == '*' || it == '"' || it == '\'' }
            if (topic.isEmpty()) return currentMemory
            val filtered = currentMemory
                .lines()
                .filter { !it.contains(topic, ignoreCase = true) }
            val joined = filtered.joinToString("\n").trim()
            val trimmed = currentMemory.trim()
            return if (joined == trimmed) {
                if (currentMemory.isEmpty()) {
                    "Note: user asked to forget \u201C$topic\u201D."
                } else {
                    "$currentMemory\n\nNote: user asked to forget \u201C$topic\u201D."
                }
            } else {
                joined
            }
        }

        if (lower.startsWith("remember that")) {
            val fact = REMEMBER_THAT_REGEX.replace(cmd, "").trim()
            if (fact.isEmpty()) return currentMemory
            val bullet = "\u2022 " + fact.first().uppercaseChar() + fact.drop(1)
            return appendBullet(currentMemory, bullet)
        }

        if (lower.startsWith("remember ")) {
            val fact = cmd.drop(9).trim()
            if (fact.isEmpty()) return currentMemory
            val bullet = "\u2022 " + fact.first().uppercaseChar() + fact.drop(1)
            return appendBullet(currentMemory, bullet)
        }

        // Freeform.
        val bullet = "\u2022 $cmd"
        return appendBullet(currentMemory, bullet)
    }

    private fun appendBullet(currentMemory: String, bullet: String): String =
        if (currentMemory.isEmpty()) bullet else "$currentMemory\n\n$bullet"
}
```

- [ ] **Step 2: Write the failing test**

File: `android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/MemoryCommandParserTest.kt`

```kotlin
package app.roamsocket.core.projects

import org.junit.Assert.assertEquals
import org.junit.Test

class MemoryCommandParserTest {

    @Test fun emptyCommandReturnsMemoryUnchanged() {
        assertEquals("", MemoryCommandParser.apply("", ""))
        assertEquals("hello", MemoryCommandParser.apply("hello", "   "))
    }

    @Test fun forgetRemovesMatchingLine() {
        val before = "\u2022 Likes dark mode\n\n\u2022 Prefers concise replies"
        val after = MemoryCommandParser.apply(before, "forget dark mode")
        assertEquals("\u2022 Prefers concise replies", after)
    }

    @Test fun forgetCaseInsensitive() {
        val before = "\u2022 Likes DARK mode\n\n\u2022 Prefers concise replies"
        val after = MemoryCommandParser.apply(before, "forget dark")
        assertEquals("\u2022 Prefers concise replies", after)
    }

    @Test fun forgetWithNoMatchAppendsNote() {
        val before = "\u2022 Likes dark mode"
        val after = MemoryCommandParser.apply(before, "forget coffee")
        assertEquals("\u2022 Likes dark mode\n\nNote: user asked to forget \u201Ccoffee\u201D.", after)
    }

    @Test fun forgetIntoEmptyMemoryAppendsNote() {
        val after = MemoryCommandParser.apply("", "forget coffee")
        assertEquals("Note: user asked to forget \u201Ccoffee\u201D.", after)
    }

    @Test fun rememberThatIAppendsBullet() {
        val after = MemoryCommandParser.apply("", "remember that I like coffee")
        assertEquals("\u2022 Like coffee", after)
    }

    @Test fun rememberThatAppendsBullet() {
        val after = MemoryCommandParser.apply("", "remember that Swift is great")
        assertEquals("\u2022 Swift is great", after)
    }

    @Test fun rememberAppendsBullet() {
        val after = MemoryCommandParser.apply("", "remember I prefer tabs")
        assertEquals("\u2022 I prefer tabs", after)
    }

    @Test fun freeformAppendsBullet() {
        val after = MemoryCommandParser.apply("", "Project ships Friday")
        assertEquals("\u2022 Project ships Friday", after)
    }

    @Test fun rememberAppendsToExistingMemory() {
        val before = "\u2022 Likes dark mode"
        val after = MemoryCommandParser.apply(before, "remember I like coffee")
        assertEquals("\u2022 Likes dark mode\n\n\u2022 I like coffee", after)
    }
}
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `cd android && ./gradlew :RoamSocketCore:test --tests "app.roamsocket.core.projects.MemoryCommandParserTest"`
Expected: PASS (10 tests, 0 failures).

- [ ] **Step 4: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/MemoryCommandParser.kt \
        android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/MemoryCommandParserTest.kt
git commit -m "feat(android): add MemoryCommandParser for project memory

Pure function that applies 'forget X' / 'remember I X' / 'remember that X'
/ freeform commands to a project's memory string, mirroring the iOS
ChatHistoryStore.applyProjectMemoryCommand heuristic. Covered by 10
unit tests including case-insensitive forget, no-match note, and
bullet appending."
```

---

## Task 3: ProjectRepository interface

**Files:**
- Create: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectRepository.kt`

**Interfaces:**
- Consumes: nothing (interface only)
- Produces: `ProjectRepository` interface, `ProjectsStateSnapshot` data class

- [ ] **Step 1: Create the interface**

File: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectRepository.kt`

```kotlin
package app.roamsocket.core.projects

import app.roamsocket.core.chats.ChatHistoryItem
import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import kotlinx.coroutines.flow.StateFlow

/**
 * Storage and mutation surface for projects + project-scoped chats.
 * Mirrors the iOS `ChatHistoryStore` project methods 1:1. The
 * Android app module plugs in a DataStore-backed implementation;
 * `InMemoryProjectRepository` is the test-double.
 */
interface ProjectRepository {

    /** All projects, newest-first. Re-publishes on every mutation. */
    val projects: StateFlow<List<ProjectItem>>

    /** Per-project chat list. Empty list when a project has no chats. */
    val projectChats: StateFlow<Map<String, List<ProjectChatItem>>>

    /** Id of the project the user is currently focused on, or null. */
    val activeProjectId: StateFlow<String?>

    // -- project CRUD --------------------------------------------------------

    fun createProject(name: String = "New project"): ProjectItem

    fun updateProjectInstructions(projectID: String, instructions: String)

    fun updateProjectMemory(projectID: String, memory: String)

    /**
     * Apply a natural-language command to a project's memory. See
     * [MemoryCommandParser] for the command grammar. Returns the
     * new memory string.
     */
    fun applyProjectMemoryCommand(projectID: String, command: String): String

    fun setActiveProject(projectID: String?)

    // -- chat-in-project -----------------------------------------------------

    /**
     * Copy a global recent into a project. Returns the new
     * [ProjectChatItem], or null if the source is incognito, the
     * source doesn't exist, or the project doesn't exist.
     */
    fun addChatToProject(source: ChatHistoryItem, projectID: String): ProjectChatItem?

    fun renameProjectChat(projectID: String, chatID: String, title: String)

    fun deleteProjectChat(projectID: String, chatID: String)

    fun archiveProjectChat(projectID: String, chatID: String)

    fun startNewChatInProject(projectID: String, selectedModel: AIModel? = null): ProjectChatItem

    fun saveProjectChatMessages(projectID: String, chatID: String, messages: List<PersistedChatMessage>)

    fun projectChatMessages(projectID: String, chatID: String): List<PersistedChatMessage>

    fun projectChatSelectedModel(projectID: String, chatID: String): AIModel?

    fun saveProjectChatSelectedModel(projectID: String, chatID: String, model: AIModel)

    // -- pruning / persistence -----------------------------------------------

    /** Remove any project chat whose `messages` list is empty. */
    fun pruneBlankProjectDrafts()

    /** Seed the in-memory state from a persisted snapshot. */
    fun replaceAll(
        projects: List<ProjectItem>,
        projectChats: Map<String, List<ProjectChatItem>>,
        activeProjectId: String?,
    )

    /** Current state, for persistence. */
    fun snapshot(): ProjectsStateSnapshot
}

/** Persisted shape; mirrors the iOS `ChatHistoryStore.Snapshot` projects subkey. */
data class ProjectsStateSnapshot(
    val projects: List<ProjectItem>,
    val projectChats: Map<String, List<ProjectChatItem>>,
    val activeProjectId: String?,
    val version: Int = 1,
)
```

- [ ] **Step 2: Verify it compiles (no test yet)**

Run: `cd android && ./gradlew :RoamSocketCore:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/ProjectRepository.kt
git commit -m "feat(android): add ProjectRepository interface

Defines the storage/mutation surface for projects + project-scoped
chats. Mirrors the iOS ChatHistoryStore project methods 1:1. No
implementation yet; InMemoryProjectRepository lands in Task 4."
```

---

## Task 4: InMemoryProjectRepository — project CRUD

**Files:**
- Create: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/InMemoryProjectRepository.kt`
- Create: `android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/InMemoryProjectRepositoryTest.kt`

**Interfaces:**
- Consumes: `ProjectRepository` (from Task 3), `MemoryCommandParser` (from Task 2), `ChatHistoryItem` (existing)
- Produces: `InMemoryProjectRepository` with `createProject`, `updateProjectInstructions`, `updateProjectMemory`, `applyProjectMemoryCommand`, `setActiveProject`, `pruneBlankProjectDrafts`, `snapshot`, `replaceAll`. Other methods throw `NotImplementedError` for now (filled in by Tasks 5-7).

- [ ] **Step 1: Create the skeleton**

File: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/InMemoryProjectRepository.kt`

```kotlin
package app.roamsocket.core.projects

import app.roamsocket.core.chats.ChatHistoryItem
import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.UUID

/**
 * Default in-memory implementation of [ProjectRepository]. All
 * mutations flow through a `mutate {}` helper so the public
 * [projects] / [projectChats] / [activeProjectId] flows stay in
 * lock-step with the source lists. The Android app module wraps
 * this with DataStore-backed persistence.
 */
class InMemoryProjectRepository : ProjectRepository {

    private val _projects = MutableStateFlow<List<ProjectItem>>(emptyList())
    override val projects: StateFlow<List<ProjectItem>> = _projects.asStateFlow()

    private val _projectChats = MutableStateFlow<Map<String, List<ProjectChatItem>>>(emptyMap())
    override val projectChats: StateFlow<Map<String, List<ProjectChatItem>>> = _projectChats.asStateFlow()

    private val _activeProjectId = MutableStateFlow<String?>(null)
    override val activeProjectId: StateFlow<String?> = _activeProjectId.asStateFlow()

    // -- project CRUD --------------------------------------------------------

    override fun createProject(name: String): ProjectItem {
        val now = System.currentTimeMillis()
        val newProject = ProjectItem(
            id = newID(),
            name = name,
            updatedAtMillis = now,
        )
        mutateProjects { list ->
            list.add(0, newProject)
        }
        mutateChats { map ->
            map[newProject.id] = emptyList()
        }
        return newProject
    }

    override fun updateProjectInstructions(projectID: String, instructions: String) {
        mutateProjects { list ->
            val idx = list.indexOfFirst { it.id == projectID }
            if (idx >= 0) {
                list[idx] = list[idx].copy(
                    instructions = instructions,
                    updatedAtMillis = System.currentTimeMillis(),
                )
            }
        }
    }

    override fun updateProjectMemory(projectID: String, memory: String) {
        mutateProjects { list ->
            val idx = list.indexOfFirst { it.id == projectID }
            if (idx >= 0) {
                val now = System.currentTimeMillis()
                list[idx] = list[idx].copy(
                    memory = memory,
                    memoryUpdatedAtMillis = now,
                    updatedAtMillis = now,
                )
            }
        }
    }

    override fun applyProjectMemoryCommand(projectID: String, command: String): String {
        val current = _projects.value.firstOrNull { it.id == projectID }?.memory ?: ""
        val next = MemoryCommandParser.apply(current, command)
        updateProjectMemory(projectID, next)
        return next
    }

    override fun setActiveProject(projectID: String?) {
        if (projectID != null && _projects.value.none { it.id == projectID }) return
        _activeProjectId.value = projectID
    }

    // -- chat-in-project (filled in by later tasks) -------------------------

    override fun addChatToProject(source: ChatHistoryItem, projectID: String): ProjectChatItem? =
        throw NotImplementedError("Task 5")

    override fun renameProjectChat(projectID: String, chatID: String, title: String) =
        throw NotImplementedError("Task 6")

    override fun deleteProjectChat(projectID: String, chatID: String) =
        throw NotImplementedError("Task 6")

    override fun archiveProjectChat(projectID: String, chatID: String) =
        throw NotImplementedError("Task 6")

    override fun startNewChatInProject(projectID: String, selectedModel: AIModel?): ProjectChatItem =
        throw NotImplementedError("Task 6")

    override fun saveProjectChatMessages(projectID: String, chatID: String, messages: List<PersistedChatMessage>) =
        throw NotImplementedError("Task 6")

    override fun projectChatMessages(projectID: String, chatID: String): List<PersistedChatMessage> =
        throw NotImplementedError("Task 6")

    override fun projectChatSelectedModel(projectID: String, chatID: String): AIModel? =
        throw NotImplementedError("Task 6")

    override fun saveProjectChatSelectedModel(projectID: String, chatID: String, model: AIModel) =
        throw NotImplementedError("Task 6")

    // -- pruning / persistence ----------------------------------------------

    override fun pruneBlankProjectDrafts() {
        mutateChats { map ->
            val changed = mutableSetOf<String>()
            for ((projectID, list) in map) {
                val filtered = list.filter { it.messages.isNotEmpty() }
                if (filtered.size != list.size) {
                    map[projectID] = filtered
                    changed.add(projectID)
                }
            }
            // No-op call to keep the receiver non-mutated when nothing
            // changed (the `changed` set is unused for now; the
            // pattern exists for the chat-history-clearing extension).
            @Suppress("UNUSED_VARIABLE") val _ = changed
        }
    }

    override fun replaceAll(
        projects: List<ProjectItem>,
        projectChats: Map<String, List<ProjectChatItem>>,
        activeProjectId: String?,
    ) {
        _projects.value = projects.sortedByDescending { it.updatedAtMillis }
        _projectChats.value = projectChats
        _activeProjectId.value = activeProjectId
    }

    override fun snapshot(): ProjectsStateSnapshot = ProjectsStateSnapshot(
        projects = _projects.value,
        projectChats = _projectChats.value,
        activeProjectId = _activeProjectId.value,
    )

    // -- internals -----------------------------------------------------------

    private inline fun mutateProjects(block: (MutableList<ProjectItem>) -> Unit) {
        val list = _projects.value.toMutableList()
        block(list)
        _projects.value = list
    }

    private inline fun mutateChats(block: (MutableMap<String, List<ProjectChatItem>>) -> Unit) {
        val map = _projectChats.value.toMutableMap()
        block(map)
        _projectChats.value = map
    }

    private fun newID(): String = UUID.randomUUID().toString()
}
```

- [ ] **Step 2: Write the project-CRUD tests**

File: `android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/InMemoryProjectRepositoryTest.kt`

```kotlin
package app.roamsocket.core.projects

import app.roamsocket.core.chats.ChatHistoryItem
import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InMemoryProjectRepositoryTest {

    @Test fun createProjectInsertsAtIndexZero() = runTest {
        val repo = InMemoryProjectRepository()
        val first = repo.createProject("First")
        val second = repo.createProject("Second")
        val list = repo.projects.first()
        assertEquals(2, list.size)
        assertEquals(second.id, list[0].id)
        assertEquals(first.id, list[1].id)
        assertEquals("First", first.name)
        assertEquals("", first.instructions)
        assertEquals("", first.memory)
        assertNull(first.memoryUpdatedAtMillis)
    }

    @Test fun createProjectInitializesEmptyChatList() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        assertEquals(emptyList<ProjectChatItem>(), repo.projectChats.value[p.id])
    }

    @Test fun updateProjectInstructionsUpdatesFieldAndUpdatedAt() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        Thread.sleep(2) // ensure updatedAtMillis is observable
        repo.updateProjectInstructions(p.id, "Think step by step.")
        val after = repo.projects.first().first { it.id == p.id }
        assertEquals("Think step by step.", after.instructions)
        assertTrue(after.updatedAtMillis > p.updatedAtMillis)
    }

    @Test fun updateProjectMemorySetsMemoryAndMemoryUpdatedAt() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        Thread.sleep(2)
        repo.updateProjectMemory(p.id, "\u2022 Likes dark mode")
        val after = repo.projects.first().first { it.id == p.id }
        assertEquals("\u2022 Likes dark mode", after.memory)
        assertNotNull(after.memoryUpdatedAtMillis)
    }

    @Test fun applyProjectMemoryCommandForgetsMatchingLine() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        repo.updateProjectMemory(p.id, "\u2022 Likes dark mode\n\n\u2022 Prefers concise replies")
        val after = repo.applyProjectMemoryCommand(p.id, "forget dark mode")
        assertEquals("\u2022 Prefers concise replies", after)
    }

    @Test fun applyProjectMemoryCommandAppendsBullet() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val after = repo.applyProjectMemoryCommand(p.id, "remember I like coffee")
        assertEquals("\u2022 I like coffee", after)
    }

    @Test fun setActiveProjectStoresId() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        repo.setActiveProject(p.id)
        assertEquals(p.id, repo.activeProjectId.first())
    }

    @Test fun setActiveProjectToUnknownIdIsNoOp() = runTest {
        val repo = InMemoryProjectRepository()
        repo.setActiveProject("does-not-exist")
        assertNull(repo.activeProjectId.first())
    }

    @Test fun setActiveProjectToNullClearsId() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        repo.setActiveProject(p.id)
        repo.setActiveProject(null)
        assertNull(repo.activeProjectId.first())
    }

    @Test fun replaceAllSeedsAllState() = runTest {
        val repo = InMemoryProjectRepository()
        val projects = listOf(
            ProjectItem(id = "p1", name = "P1", updatedAtMillis = 100L),
            ProjectItem(id = "p2", name = "P2", updatedAtMillis = 200L),
        )
        val chats = mapOf("p1" to listOf<ProjectChatItem>())
        repo.replaceAll(projects, chats, "p2")
        assertEquals(2, repo.projects.value.size)
        assertEquals("p2", repo.projects.value[0].id) // newest first
        assertEquals("p2", repo.activeProjectId.value)
    }

    @Test fun snapshotRoundTripsThroughReplaceAll() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        repo.updateProjectMemory(p.id, "hi")
        repo.setActiveProject(p.id)
        val snap = repo.snapshot()
        val fresh = InMemoryProjectRepository()
        fresh.replaceAll(snap.projects, snap.projectChats, snap.activeProjectId)
        assertEquals(snap.projects, fresh.projects.value)
        assertEquals(snap.activeProjectId, fresh.activeProjectId.value)
    }

    @Test fun pruneBlankProjectDraftsRemovesEmptyChats() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        // Inject a blank-draft project chat directly through replaceAll
        // (this is the only path that lets us seed a blank chat in
        // a project without throwing on the unimplemented
        // startNewChatInProject). Later tasks will exercise the
        // public startNewChatInProject → pruneBlankProjectDrafts path.
        val blank = ProjectChatItem(
            id = "blank", title = "New chat", lastMessageAtMillis = 0L,
        )
        repo.replaceAll(
            projects = listOf(p),
            projectChats = mapOf(p.id to listOf(blank)),
            activeProjectId = null,
        )
        repo.pruneBlankProjectDrafts()
        assertEquals(emptyList<ProjectChatItem>(), repo.projectChats.value[p.id])
    }
}
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `cd android && ./gradlew :RoamSocketCore:test --tests "app.roamsocket.core.projects.InMemoryProjectRepositoryTest"`
Expected: PASS (12 tests, 0 failures).

- [ ] **Step 4: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/InMemoryProjectRepository.kt \
        android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/InMemoryProjectRepositoryTest.kt
git commit -m "feat(android): add InMemoryProjectRepository with project CRUD

createProject / updateProjectInstructions / updateProjectMemory /
applyProjectMemoryCommand / setActiveProject / pruneBlankProjectDrafts
plus persistence helpers (replaceAll, snapshot). Chat-in-project
methods throw NotImplementedError; filled in by later tasks. Covered
by 12 unit tests including applyProjectMemoryCommand integration with
MemoryCommandParser and snapshot round-trip."
```

---

## Task 5: InMemoryProjectRepository — addChatToProject

**Files:**
- Modify: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/InMemoryProjectRepository.kt` (replace the `throw NotImplementedError("Task 5")` on `addChatToProject`)
- Modify: `android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/InMemoryProjectRepositoryTest.kt` (append tests)

**Interfaces:**
- Consumes: `ProjectRepository.addChatToProject(source: ChatHistoryItem, projectID: String): ProjectChatItem?`
- Produces: real implementation that copies the source into the project, preserving title/messages/model; rejects incognito.

- [ ] **Step 1: Implement `addChatToProject`**

In `InMemoryProjectRepository.kt`, replace the existing `addChatToProject` method body (currently `throw NotImplementedError("Task 5")`) with:

```kotlin
    override fun addChatToProject(source: ChatHistoryItem, projectID: String): ProjectChatItem? {
        if (source.isIncognito) return null
        if (_projects.value.none { it.id == projectID }) return null

        val newChat = ProjectChatItem(
            id = newID(),
            title = source.title,
            lastMessageAtMillis = source.lastMessageAtMillis,
            messages = source.messages,
            isArchived = false,
            selectedModel = source.selectedProvider?.let { providerRaw ->
                runCatching { ProviderId.fromRawValue(providerRaw) }.getOrNull()?.let { provider ->
                    AIModel(
                        provider = provider,
                        modelID = source.selectedModel.orEmpty(),
                        displayName = source.selectedModel.orEmpty(),
                    )
                }
            },
            titleIsUserEdited = source.titleIsUserEdited,
            didAutoTitle = source.didAutoTitle,
            autoTitleAtUserCount = source.autoTitleAtUserCount,
        )
        mutateChats { map ->
            val list = map[projectID]?.toMutableList() ?: mutableListOf()
            list.add(0, newChat)
            map[projectID] = list
        }
        bumpProjectUpdatedAt(projectID)
        return newChat
    }
```

Then add a private helper at the bottom of the class (alongside the other internals):

```kotlin
    private fun bumpProjectUpdatedAt(projectID: String) {
        mutateProjects { list ->
            val idx = list.indexOfFirst { it.id == projectID }
            if (idx >= 0) {
                list[idx] = list[idx].copy(updatedAtMillis = System.currentTimeMillis())
            }
        }
    }
```

- [ ] **Step 2: Append tests for `addChatToProject`**

Append to `InMemoryProjectRepositoryTest.kt`:

```kotlin
    @Test fun addChatToProjectCopiesGlobalChatIntoProject() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val source = ChatHistoryItem(
            id = "c1",
            title = "SSE vs WebSockets",
            lastMessageAtMillis = 1_700_000_000_000L,
            messages = listOf(
                PersistedChatMessage(
                    id = "u1", role = PersistedChatMessage.Role.USER,
                    content = "What is SSE?", timestampMillis = 1_700_000_000_000L,
                ),
            ),
        )
        val copy = repo.addChatToProject(source, p.id)
        assertNotNull(copy)
        assertEquals(source.title, copy!!.title)
        assertEquals(1, copy.messages.size)
        assertEquals(1, repo.projectChats.value[p.id]!!.size)
        assertEquals(copy.id, repo.projectChats.value[p.id]!![0].id)
    }

    @Test fun addChatToProjectRejectsIncognito() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val incognito = ChatHistoryItem(
            id = "c1", title = "secret", lastMessageAtMillis = 0L,
            isIncognito = true,
        )
        assertNull(repo.addChatToProject(incognito, p.id))
        assertEquals(emptyList<ProjectChatItem>(), repo.projectChats.value[p.id])
    }

    @Test fun addChatToProjectOnUnknownProjectReturnsNull() = runTest {
        val repo = InMemoryProjectRepository()
        val source = ChatHistoryItem(id = "c1", title = "x", lastMessageAtMillis = 0L)
        assertNull(repo.addChatToProject(source, "missing"))
    }

    @Test fun addChatToProjectBumpsProjectUpdatedAt() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        Thread.sleep(2)
        val before = repo.projects.value.first { it.id == p.id }.updatedAtMillis
        repo.addChatToProject(
            ChatHistoryItem(id = "c1", title = "x", lastMessageAtMillis = 0L),
            p.id,
        )
        val after = repo.projects.value.first { it.id == p.id }.updatedAtMillis
        assertTrue(after > before)
    }
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `cd android && ./gradlew :RoamSocketCore:test --tests "app.roamsocket.core.projects.InMemoryProjectRepositoryTest"`
Expected: PASS (16 tests, 0 failures — 12 existing + 4 new).

- [ ] **Step 4: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/InMemoryProjectRepository.kt \
        android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/InMemoryProjectRepositoryTest.kt
git commit -m "feat(android): addChatToProject copies global chats into a project

Mirrors iOS ChatHistoryStore.addChatToProject: rejects incognito
sources, returns null on unknown project, reconstructs AIModel from
ChatHistoryItem's (provider, modelID) strings best-effort, preserves
title/messages/auto-title flags, and bumps the project's updatedAt.
Covered by 4 new tests (16 total)."
```

---

## Task 6: InMemoryProjectRepository — chat lifecycle (start, save, rename, delete, archive, model)

**Files:**
- Modify: `android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/InMemoryProjectRepository.kt`
- Modify: `android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/InMemoryProjectRepositoryTest.kt`

**Interfaces:**
- Consumes: existing class state
- Produces: real implementations for `startNewChatInProject`, `saveProjectChatMessages`, `projectChatMessages`, `projectChatSelectedModel`, `saveProjectChatSelectedModel`, `renameProjectChat`, `deleteProjectChat`, `archiveProjectChat`.

- [ ] **Step 1: Replace the six `NotImplementedError("Task 6")` method bodies**

In `InMemoryProjectRepository.kt`, replace the chat-lifecycle methods so the class looks like:

```kotlin
    override fun startNewChatInProject(projectID: String, selectedModel: AIModel?): ProjectChatItem {
        val now = System.currentTimeMillis()
        val newChat = ProjectChatItem(
            id = newID(),
            title = "New chat",
            lastMessageAtMillis = now,
            selectedModel = selectedModel,
        )
        mutateChats { map ->
            val list = (map[projectID] ?: emptyList()).toMutableList()
            list.removeAll { it.messages.isEmpty() }
            list.add(0, newChat)
            map[projectID] = list
        }
        bumpProjectUpdatedAt(projectID)
        return newChat
    }

    override fun saveProjectChatMessages(
        projectID: String, chatID: String, messages: List<PersistedChatMessage>,
    ) {
        mutateChats { map ->
            val list = map[projectID]?.toMutableList() ?: return@mutateChats
            val idx = list.indexOfFirst { it.id == chatID }
            if (idx < 0) return@mutateChats
            val current = list[idx]
            val lastAt = messages.lastOrNull()?.timestampMillis ?: current.lastMessageAtMillis
            val nextTitle = if (
                !current.titleIsUserEdited && !current.didAutoTitle && messages.isNotEmpty()
            ) {
                derivedTitle(messages)
            } else {
                current.title
            }
            list[idx] = current.copy(
                messages = messages,
                lastMessageAtMillis = lastAt,
                title = nextTitle,
            )
        }
        bumpProjectUpdatedAt(projectID)
    }

    override fun projectChatMessages(projectID: String, chatID: String): List<PersistedChatMessage> {
        val list = _projectChats.value[projectID] ?: return emptyList()
        return list.firstOrNull { it.id == chatID }?.messages ?: emptyList()
    }

    override fun projectChatSelectedModel(projectID: String, chatID: String): AIModel? {
        val list = _projectChats.value[projectID] ?: return null
        return list.firstOrNull { it.id == chatID }?.selectedModel
    }

    override fun saveProjectChatSelectedModel(projectID: String, chatID: String, model: AIModel) {
        mutateChats { map ->
            val list = map[projectID]?.toMutableList() ?: return@mutateChats
            val idx = list.indexOfFirst { it.id == chatID }
            if (idx < 0) return@mutateChats
            list[idx] = list[idx].copy(selectedModel = model)
        }
    }

    override fun renameProjectChat(projectID: String, chatID: String, title: String) {
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        mutateChats { map ->
            val list = map[projectID]?.toMutableList() ?: return@mutateChats
            val idx = list.indexOfFirst { it.id == chatID }
            if (idx < 0) return@mutateChats
            list[idx] = list[idx].copy(
                title = trimmed,
                titleIsUserEdited = true,
                didAutoTitle = true,
            )
        }
        bumpProjectUpdatedAt(projectID)
    }

    override fun deleteProjectChat(projectID: String, chatID: String) {
        mutateChats { map ->
            val list = map[projectID]?.toMutableList() ?: return@mutateChats
            list.removeAll { it.id == chatID }
            map[projectID] = list
        }
    }

    override fun archiveProjectChat(projectID: String, chatID: String) {
        mutateChats { map ->
            val list = map[projectID]?.toMutableList() ?: return@mutateChats
            val idx = list.indexOfFirst { it.id == chatID }
            if (idx < 0) return@mutateChats
            list[idx] = list[idx].copy(isArchived = true)
        }
    }
```

Then add a private helper alongside the others:

```kotlin
    private fun derivedTitle(messages: List<PersistedChatMessage>): String {
        val firstUser = messages.firstOrNull { it.role == PersistedChatMessage.Role.USER }
            ?: return "New chat"
        val raw = firstUser.content.trim().replace(Regex("\\s+"), " ")
        if (raw.isEmpty()) return "New chat"
        val words = raw.split(' ').take(6).joinToString(" ")
        return if (words.length <= 48) {
            words
        } else {
            words.substring(0, 48).trimEnd { it == ' ' || it == ',' } + "\u2026"
        }
    }
```

- [ ] **Step 2: Append the chat-lifecycle tests**

Append to `InMemoryProjectRepositoryTest.kt`:

```kotlin
    @Test fun startNewChatInProjectRemovesBlankDraftAndInsertsAtTop() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val first = repo.startNewChatInProject(p.id)
        val second = repo.startNewChatInProject(p.id)
        val list = repo.projectChats.value[p.id]!!
        assertEquals(2, list.size)
        assertEquals(second.id, list[0].id)
        assertEquals(first.id, list[1].id)
        assertEquals("New chat", first.title)
    }

    @Test fun saveProjectChatMessagesUpdatesTranscriptAndTitle() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        val messages = listOf(
            PersistedChatMessage(
                id = "u1", role = PersistedChatMessage.Role.USER,
                content = "What's the difference between SSE and WebSockets?",
                timestampMillis = 1_700_000_000_000L,
            ),
        )
        repo.saveProjectChatMessages(p.id, chat.id, messages)
        val list = repo.projectChats.value[p.id]!!
        assertEquals(1, list[0].messages.size)
        assertTrue(list[0].title.startsWith("What's the difference"))
    }

    @Test fun saveProjectChatMessagesOnUnknownChatIsNoOp() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        repo.saveProjectChatMessages(
            p.id, "does-not-exist",
            listOf(
                PersistedChatMessage(
                    id = "u1", role = PersistedChatMessage.Role.USER,
                    content = "hi", timestampMillis = 0L,
                ),
            ),
        )
        assertEquals(emptyList<ProjectChatItem>(), repo.projectChats.value[p.id])
    }

    @Test fun projectChatMessagesReturnsMessagesForChat() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        val msgs = listOf(
            PersistedChatMessage(
                id = "u1", role = PersistedChatMessage.Role.USER,
                content = "hi", timestampMillis = 1L,
            ),
        )
        repo.saveProjectChatMessages(p.id, chat.id, msgs)
        assertEquals(msgs, repo.projectChatMessages(p.id, chat.id))
    }

    @Test fun projectChatMessagesOnUnknownChatReturnsEmpty() = runTest {
        val repo = InMemoryProjectRepository()
        assertEquals(emptyList<PersistedChatMessage>(), repo.projectChatMessages("missing", "missing"))
    }

    @Test fun projectChatSelectedModelRoundTrips() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        val model = AIModel(
            provider = ProviderId.Anthropic,
            modelID = "claude-3-5-sonnet-20241022",
            displayName = "Claude 3.5 Sonnet",
        )
        repo.saveProjectChatSelectedModel(p.id, chat.id, model)
        assertEquals(model, repo.projectChatSelectedModel(p.id, chat.id))
    }

    @Test fun renameProjectChatTrimsAndSetsFlags() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        repo.renameProjectChat(p.id, chat.id, "  Hello  ")
        val updated = repo.projectChats.value[p.id]!![0]
        assertEquals("Hello", updated.title)
        assertTrue(updated.titleIsUserEdited)
        assertTrue(updated.didAutoTitle)
    }

    @Test fun renameProjectChatWithBlankTitleIsNoOp() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        repo.renameProjectChat(p.id, chat.id, "   ")
        assertEquals("New chat", repo.projectChats.value[p.id]!![0].title)
    }

    @Test fun deleteProjectChatRemovesIt() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        repo.saveProjectChatMessages(
            p.id, chat.id,
            listOf(
                PersistedChatMessage(
                    id = "u1", role = PersistedChatMessage.Role.USER,
                    content = "hi", timestampMillis = 1L,
                ),
            ),
        )
        repo.deleteProjectChat(p.id, chat.id)
        assertEquals(emptyList<ProjectChatItem>(), repo.projectChats.value[p.id])
    }

    @Test fun archiveProjectChatSetsFlag() = runTest {
        val repo = InMemoryProjectRepository()
        val p = repo.createProject("X")
        val chat = repo.startNewChatInProject(p.id)
        repo.saveProjectChatMessages(
            p.id, chat.id,
            listOf(
                PersistedChatMessage(
                    id = "u1", role = PersistedChatMessage.Role.USER,
                    content = "hi", timestampMillis = 1L,
                ),
            ),
        )
        repo.archiveProjectChat(p.id, chat.id)
        assertTrue(repo.projectChats.value[p.id]!![0].isArchived)
    }
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `cd android && ./gradlew :RoamSocketCore:test --tests "app.roamsocket.core.projects.InMemoryProjectRepositoryTest"`
Expected: PASS (26 tests, 0 failures — 16 existing + 10 new).

- [ ] **Step 4: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/RoamSocketCore/src/main/kotlin/app/roamsocket/core/projects/InMemoryProjectRepository.kt \
        android/RoamSocketCore/src/test/kotlin/app/roamsocket/core/projects/InMemoryProjectRepositoryTest.kt
git commit -m "feat(android): add project chat lifecycle to InMemoryProjectRepository

Implements startNewChatInProject, saveProjectChatMessages,
projectChatMessages, projectChatSelectedModel +
saveProjectChatSelectedModel, renameProjectChat, deleteProjectChat,
archiveProjectChat. Mirrors the iOS ChatHistoryStore project-chat
methods 1:1. New derivedTitle helper reuses the existing chat-history
heuristic for interim titles. Covered by 10 new tests (26 total)."
```

---

## Task 7: DataStoreProjectRepository (app/data)

**Files:**
- Create: `android/app/src/main/kotlin/app/roamsocket/android/data/DataStoreProjectRepository.kt`
- Create: `android/app/src/test/kotlin/app/roamsocket/android/data/DataStoreProjectRepositoryTest.kt`

**Interfaces:**
- Consumes: `ProjectRepository` (from Task 3), `InMemoryProjectRepository` (from Tasks 4-6), `ProjectsStateSnapshot` (from Task 3)
- Produces: a `DataStoreProjectRepository` class that mirrors the in-memory repo to a single DataStore JSON blob, plus a Robolectric test.

- [ ] **Step 1: Create the DataStore wrapper**

File: `android/app/src/main/kotlin/app/roamsocket/android/data/DataStoreProjectRepository.kt`

```kotlin
package app.roamsocket.android.data

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.roamsocket.core.chats.ChatHistoryItem
import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.projects.InMemoryProjectRepository
import app.roamsocket.core.projects.ProjectChatItem
import app.roamsocket.core.projects.ProjectItem
import app.roamsocket.core.projects.ProjectRepository
import app.roamsocket.core.projects.ProjectsStateSnapshot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

private val Context.projectDataStore by preferencesDataStore(name = "roamsocket_projects")

/**
 * DataStore-backed project repository. Stores the full project state
 * (projects, projectChats, activeProjectId) as a single JSON blob
 * under one preference key, matching the iOS `ChatHistoryStore`
 * single-blob strategy (`ios/.../ChatHistory.swift`).
 *
 * Mirrors the structure of `DataStoreChatHistoryRepository`. The
 * underlying [InMemoryProjectRepository] is the source of truth at
 * runtime; DataStore mirrors it on every state change.
 */
class DataStoreProjectRepository(
    context: Context,
    private val flowScope: CoroutineScope,
    private val json: Json = DEFAULT_JSON,
) : ProjectRepository {

    private val store = context.applicationContext.projectDataStore
    private val inMemory = InMemoryProjectRepository()
    private val ready = MutableStateFlow(false)

    init {
        flowScope.launch {
            val snapshot = readFromDisk()
            inMemory.replaceAll(snapshot.projects, snapshot.projectChats, snapshot.activeProjectId)
            ready.value = true
        }
        flowScope.launch {
            // Persist on every change once the initial load is done.
            // The first emission after `ready` flips carries any
            // mutations queued before load finished.
            inMemory.projects.collect {
                if (ready.value) writeToDisk(inMemory.snapshot())
            }
        }
        flowScope.launch {
            inMemory.projectChats.collect {
                if (ready.value) writeToDisk(inMemory.snapshot())
            }
        }
    }

    override val projects: StateFlow<List<ProjectItem>> = inMemory.projects
    override val projectChats: StateFlow<Map<String, List<ProjectChatItem>>> = inMemory.projectChats
    override val activeProjectId: StateFlow<String?> = inMemory.activeProjectId

    override fun createProject(name: String): ProjectItem = inMemory.createProject(name)
    override fun updateProjectInstructions(projectID: String, instructions: String) =
        inMemory.updateProjectInstructions(projectID, instructions)
    override fun updateProjectMemory(projectID: String, memory: String) =
        inMemory.updateProjectMemory(projectID, memory)
    override fun applyProjectMemoryCommand(projectID: String, command: String): String =
        inMemory.applyProjectMemoryCommand(projectID, command)
    override fun setActiveProject(projectID: String?) = inMemory.setActiveProject(projectID)
    override fun addChatToProject(source: ChatHistoryItem, projectID: String): ProjectChatItem? =
        inMemory.addChatToProject(source, projectID)
    override fun renameProjectChat(projectID: String, chatID: String, title: String) =
        inMemory.renameProjectChat(projectID, chatID, title)
    override fun deleteProjectChat(projectID: String, chatID: String) =
        inMemory.deleteProjectChat(projectID, chatID)
    override fun archiveProjectChat(projectID: String, chatID: String) =
        inMemory.archiveProjectChat(projectID, chatID)
    override fun startNewChatInProject(projectID: String, selectedModel: AIModel?): ProjectChatItem =
        inMemory.startNewChatInProject(projectID, selectedModel)
    override fun saveProjectChatMessages(projectID: String, chatID: String, messages: List<PersistedChatMessage>) =
        inMemory.saveProjectChatMessages(projectID, chatID, messages)
    override fun projectChatMessages(projectID: String, chatID: String): List<PersistedChatMessage> =
        inMemory.projectChatMessages(projectID, chatID)
    override fun projectChatSelectedModel(projectID: String, chatID: String): AIModel? =
        inMemory.projectChatSelectedModel(projectID, chatID)
    override fun saveProjectChatSelectedModel(projectID: String, chatID: String, model: AIModel) =
        inMemory.saveProjectChatSelectedModel(projectID, chatID, model)
    override fun pruneBlankProjectDrafts() = inMemory.pruneBlankProjectDrafts()
    override fun replaceAll(
        projects: List<ProjectItem>,
        projectChats: Map<String, List<ProjectChatItem>>,
        activeProjectId: String?,
    ) = inMemory.replaceAll(projects, projectChats, activeProjectId)
    override fun snapshot(): ProjectsStateSnapshot = inMemory.snapshot()

    /** Force a synchronous load (mostly useful for tests). */
    suspend fun awaitReady() {
        if (ready.value) return
        ready.first { it }
    }

    private suspend fun readFromDisk(): ProjectsStateSnapshot {
        val raw = store.data.first()[KEY_JSON] ?: return emptySnapshot()
        return runCatching {
            json.decodeFromString(ProjectsStateSnapshot.serializer(), raw)
        }.getOrDefault(emptySnapshot())
    }

    private suspend fun writeToDisk(snapshot: ProjectsStateSnapshot) {
        val encoded = json.encodeToString(ProjectsStateSnapshot.serializer(), snapshot)
        store.edit { prefs -> prefs[KEY_JSON] = encoded }
    }

    private fun emptySnapshot() = ProjectsStateSnapshot(
        projects = emptyList(),
        projectChats = emptyMap(),
        activeProjectId = null,
    )

    companion object {
        private val DEFAULT_JSON = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            prettyPrint = false
        }
        private val KEY_JSON: Preferences.Key<String> = stringPreferencesKey("projects_state_json")
    }
}
```

- [ ] **Step 2: Write the Robolectric persistence test**

File: `android/app/src/test/kotlin/app/roamsocket/android/data/DataStoreProjectRepositoryTest.kt`

```kotlin
package app.roamsocket.android.data

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * End-to-end persistence test for the project DataStore wrapper.
 * Mirrors `DataStoreChatHistoryRepositoryTest`.
 */
@RunWith(AndroidJUnit4::class)
@Config(manifest = Config.NONE, sdk = [34])
class DataStoreProjectRepositoryTest {

    private lateinit var context: android.content.Context
    private val testScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
    }

    @After
    fun tearDown() {
        runBlocking {
            val file = java.io.File(
                context.filesDir.parentFile,
                "datastore/roamsocket_projects.preferences_pb",
            )
            if (file.exists()) file.delete()
        }
    }

    @Test
    fun projectStateSurvivesAcrossInstances() = runBlocking {
        val first = DataStoreProjectRepository(context, testScope)
        first.awaitReady()
        val p = first.createProject("Phase 1")
        first.updateProjectMemory(p.id, "hello world")
        first.setActiveProject(p.id)
        // Allow the persist collector to flush.
        delay(80)

        val second = DataStoreProjectRepository(context, testScope)
        second.awaitReady()
        val resumed = second.snapshot().projects.firstOrNull { it.id == p.id }
        assertNotNull("project $p.id should be persisted", resumed)
        assertEquals("hello world", resumed!!.memory)
        assertEquals(p.id, second.snapshot().activeProjectId)
    }

    @Test
    fun projectChatMessagesSurviveAcrossInstances() = runBlocking {
        val first = DataStoreProjectRepository(context, testScope)
        first.awaitReady()
        val p = first.createProject("Phase 1")
        val chat = first.startNewChatInProject(
            p.id,
            selectedModel = AIModel(
                provider = ProviderId.Anthropic,
                modelID = "claude-3-5-sonnet-20241022",
                displayName = "Claude 3.5 Sonnet",
            ),
        )
        first.saveProjectChatMessages(
            p.id, chat.id,
            listOf(
                app.roamsocket.core.chats.PersistedChatMessage(
                    id = "u-1", role = app.roamsocket.core.chats.PersistedChatMessage.Role.USER,
                    content = "hello", timestampMillis = 1L,
                ),
            ),
        )
        delay(80)

        val second = DataStoreProjectRepository(context, testScope)
        second.awaitReady()
        val messages = second.projectChatMessages(p.id, chat.id)
        assertEquals(1, messages.size)
        assertEquals("hello", messages[0].content)
        assertTrue(
            second.projectChats.value[p.id]?.firstOrNull { it.id == chat.id }?.selectedModel != null,
        )
    }
}
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `cd android && ./gradlew :app:test --tests "app.roamsocket.android.data.DataStoreProjectRepositoryTest"`
Expected: PASS (2 tests, 0 failures).

- [ ] **Step 4: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/app/src/main/kotlin/app/roamsocket/android/data/DataStoreProjectRepository.kt \
        android/app/src/test/kotlin/app/roamsocket/android/data/DataStoreProjectRepositoryTest.kt
git commit -m "feat(android): add DataStoreProjectRepository (single JSON blob)

Wraps InMemoryProjectRepository and persists projects + projectChats +
activeProjectId as a single JSON blob to a dedicated DataStore
preferences file, matching the iOS ChatHistoryStore single-blob
strategy. End-to-end persistence verified via Robolectric across two
repository instances (project state and project chat messages both
survive)."
```

---

## Task 8: AppContainer wiring

**Files:**
- Modify: `android/app/src/main/kotlin/app/roamsocket/android/AppContainer.kt`

**Interfaces:**
- Consumes: `DataStoreProjectRepository` (from Task 7)
- Produces: `AppContainer.projectRepository: ProjectRepository` exposed to the coordinator.

- [ ] **Step 1: Read the current `AppContainer.kt` to find the right insertion point**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
grep -n "chatHistoryRepository\|DataStoreChatHistoryRepository\|appScope" android/app/src/main/kotlin/app/roamsocket/android/AppContainer.kt
```

- [ ] **Step 2: Add the project repository field**

In `AppContainer.kt`, find the line that constructs `DataStoreChatHistoryRepository` (or `chatHistoryRepository`) and add a sibling construction right after it. Concretely:

1. Add an import near the top of the file:
   ```kotlin
   import app.roamsocket.core.projects.ProjectRepository
   ```
2. Add a public read-only field after the existing `chatHistoryRepository` line:
   ```kotlin
   /** Project state — DataStore-backed; see [DataStoreProjectRepository]. */
   val projectRepository: ProjectRepository =
       DataStoreProjectRepository(context, appScope)
   ```

If `AppContainer` is currently a class with a primary constructor that takes `context`, you may need to inline the construction in the property initializer (the existing code likely does the same for `chatHistoryRepository` — mirror its style).

- [ ] **Step 3: Verify it compiles**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/app/src/main/kotlin/app/roamsocket/android/AppContainer.kt
git commit -m "feat(android): wire DataStoreProjectRepository into AppContainer

Exposes a ProjectRepository instance on the AppContainer so the
ChatHistoryStore coordinator (Task 9) and Compose screens can reach
the persisted project state through the standard DI surface."
```

---

## Task 9: ChatHistoryStore coordinator (app/ui/sidebar)

**Files:**
- Modify: `android/app/src/main/kotlin/app/roamsocket/android/ui/sidebar/ChatHistoryStore.kt`

**Interfaces:**
- Consumes: `ProjectRepository` (via `AppContainer`)
- Produces: project coordinator methods on `ChatHistoryStore` (1:1 with iOS); the `addChatToProject` no-op becomes a real implementation.

- [ ] **Step 1: Update imports + constructor**

At the top of `ChatHistoryStore.kt`:

1. Add imports:
   ```kotlin
   import app.roamsocket.core.projects.ProjectChatItem
   import app.roamsocket.core.projects.ProjectItem
   import app.roamsocket.core.projects.ProjectRepository
   import app.roamsocket.core.providers.AIModel
   import kotlinx.coroutines.flow.combine
   ```

2. Update the `ChatHistoryStore` class signature to take a `ProjectRepository`:
   ```kotlin
   class ChatHistoryStore internal constructor(
       private val repository: ChatHistoryRepository,
       private val projectRepository: ProjectRepository,
       flowScope: CoroutineScope,
   ) { ... }
   ```

3. Update the `rememberChatHistoryStore()` composable to pass the new argument:
   ```kotlin
   @Composable
   fun rememberChatHistoryStore(): ChatHistoryStore {
       val container: AppContainer = LocalAppContainer.current
       return remember(container) {
           ChatHistoryStore(
               repository = container.chatHistoryRepository,
               projectRepository = container.projectRepository,
               flowScope = container.appScope,
           )
       }
   }
   ```

- [ ] **Step 2: Add the project coordinator methods**

Inside the `ChatHistoryStore` class, after the existing `addChatToProject` no-op, replace it and add the rest. The full new surface:

```kotlin
    // -- Project coordinator -------------------------------------------------

    val projects: StateFlow<List<ProjectItem>> = projectRepository.projects
    val projectChats: StateFlow<Map<String, List<ProjectChatItem>>> = projectRepository.projectChats
    val activeProjectId: StateFlow<String?> = projectRepository.activeProjectId

    /** The currently-active project (resolved from [activeProjectId]). */
    val activeProject: StateFlow<ProjectItem?> = combine(
        projectRepository.projects,
        projectRepository.activeProjectId,
    ) { list, id -> list.firstOrNull { it.id == id } }
        .let { flow ->
            kotlinx.coroutines.flow.MutableStateFlow<ProjectItem?>(null).also { mirror ->
                flowScope.launch { flow.collect { mirror.value = it } }
            }
        }

    fun chatsFor(project: ProjectItem): List<ProjectChatItem> =
        projectRepository.projectChats.value[project.id].orEmpty()
            .filter { !it.isArchived && it.messages.isNotEmpty() }

    fun createProject(name: String): ProjectItem = projectRepository.createProject(name)

    fun updateProjectInstructions(projectID: String, instructions: String) =
        projectRepository.updateProjectInstructions(projectID, instructions)

    fun updateProjectMemory(projectID: String, memory: String) =
        projectRepository.updateProjectMemory(projectID, memory)

    fun applyProjectMemoryCommand(projectID: String, command: String): String =
        projectRepository.applyProjectMemoryCommand(projectID, command)

    fun setActiveProject(projectID: String?) = projectRepository.setActiveProject(projectID)

    /**
     * Mark a project chat as the user's current focus. Sets the
     * project as active and pins the chat id on the chat-history
     * repository so the ChatViewModel can resolve the active chat.
     * Does NOT add a stub to the global recents list.
     */
    fun openProjectChatAsActive(projectID: String, chatID: String) {
        if (projectRepository.projects.value.none { it.id == projectID }) return
        projectRepository.setActiveProject(projectID)
        repository.activeChatId = chatID
    }

    fun addChatToProject(chatID: String, projectID: String): ProjectChatItem? {
        val source = repository.snapshot().firstOrNull { it.id == chatID } ?: return null
        if (source.isIncognito) return null
        return projectRepository.addChatToProject(source, projectID)
    }

    fun renameProjectChat(projectID: String, chatID: String, title: String) =
        projectRepository.renameProjectChat(projectID, chatID, title)

    fun deleteProjectChat(projectID: String, chatID: String) =
        projectRepository.deleteProjectChat(projectID, chatID)

    fun archiveProjectChat(projectID: String, chatID: String) =
        projectRepository.archiveProjectChat(projectID, chatID)

    fun startNewChatInProject(project: ProjectItem, selectedModel: AIModel? = null): ProjectChatItem =
        projectRepository.startNewChatInProject(project.id, selectedModel)

    fun saveProjectChatMessages(projectID: String, chatID: String, messages: List<PersistedChatMessage>) =
        projectRepository.saveProjectChatMessages(projectID, chatID, messages)

    fun projectChatMessages(projectID: String, chatID: String): List<PersistedChatMessage> =
        projectRepository.projectChatMessages(projectID, chatID)

    fun projectChatSelectedModel(projectID: String, chatID: String): AIModel? =
        projectRepository.projectChatSelectedModel(projectID, chatID)

    fun saveProjectChatSelectedModel(projectID: String, chatID: String, model: AIModel) =
        projectRepository.saveProjectChatSelectedModel(projectID, chatID, model)
```

- [ ] **Step 3: Remove the old `addChatToProject` no-op**

Delete the old `addChatToProject(@Suppress("UNUSED_PARAMETER") chatID, @Suppress("UNUSED_PARAMETER") projectID)` method (and the stale "Projects feature is iOS-only for now" comment).

- [ ] **Step 4: Verify it compiles**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL (with possible warnings about unused symbols that will be used in later tasks).

- [ ] **Step 5: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/app/src/main/kotlin/app/roamsocket/android/ui/sidebar/ChatHistoryStore.kt
git commit -m "feat(android): wire ProjectRepository into ChatHistoryStore

ChatHistoryStore becomes the app-level coordinator for both
ChatHistoryRepository and ProjectRepository, matching the iOS
ChatHistoryStore role. Adds projects / projectChats / activeProject
flows plus 1:1 coordinator methods (createProject,
updateProjectInstructions, updateProjectMemory,
applyProjectMemoryCommand, setActiveProject, addChatToProject,
renameProjectChat, deleteProjectChat, archiveProjectChat,
startNewChatInProject, saveProjectChatMessages, etc.). Replaces the
old addChatToProject no-op with a real implementation that resolves
the source from ChatHistoryRepository."
```

---

## Task 10: ChatTitleGenerator (lightweight-model-driven)

**Files:**
- Create: `android/app/src/main/kotlin/app/roamsocket/android/ui/chats/ChatTitleGenerator.kt`
- Create: `android/app/src/test/kotlin/app/roamsocket/android/ui/chats/ChatTitleGeneratorTest.kt`

**Interfaces:**
- Consumes: `LightweightTaskRunner` (existing), `ChatHistoryItem` (existing)
- Produces: `ChatTitleGenerator.sanitize(raw)`, `ChatTitleGenerator.suggestTitle(container, messages, currentTitle)`.

- [ ] **Step 1: Create the generator**

File: `android/app/src/main/kotlin/app/roamsocket/android/ui/chats/ChatTitleGenerator.kt`

```kotlin
package app.roamsocket.android.ui.chats

import app.roamsocket.android.AppContainer
import app.roamsocket.android.ui.lightweight.LightweightTaskRunner
import app.roamsocket.core.chats.PersistedChatMessage

/**
 * Suggests a short display title for a chat. Mirrors the iOS
 * `Chats/ChatTitleGenerator.swift` surface:
 *
 * 1. If the user has a linked lightweight model, ask it for a
 *    short title (1-6 words) and sanitize the result.
 * 2. Otherwise, fall back to the heuristic "first 6 words of the
 *    first user message".
 *
 * Never overwrites a user-edited title; the caller is responsible
 * for that check.
 */
object ChatTitleGenerator {

    const val MAX_TITLE_LENGTH: Int = 48

    private const val SYSTEM_PROMPT =
        "You title chat conversations. Reply with a short, descriptive " +
            "title of 1-6 words. No quotes, no trailing punctuation, no " +
            "explanation. Output only the title."

    /**
     * Suggest a title for the chat whose first user message is
     * `messages.firstOrNull { role == USER }`. Returns
     * `currentTitle` unchanged when the chat has no user message
     * yet.
     */
    suspend fun suggestTitle(
        container: AppContainer,
        messages: List<PersistedChatMessage>,
        currentTitle: String,
    ): String {
        val firstUser = messages.firstOrNull { it.role == PersistedChatMessage.Role.USER }
            ?: return currentTitle
        val firstText = firstUser.content.trim()
        if (firstText.isEmpty()) return currentTitle

        val lightweight = LightweightTaskRunner.complete(
            container = container,
            system = SYSTEM_PROMPT,
            user = firstText,
            maxTokens = 16,
        )
        if (!lightweight.isNullOrBlank()) {
            return sanitize(lightweight)
        }
        return heuristic(firstText)
    }

    /** First 6 words of [text], capped at [MAX_TITLE_LENGTH]. */
    fun heuristic(text: String): String {
        val cleaned = text.trim().replace(Regex("\\s+"), " ")
        if (cleaned.isEmpty()) return ""
        val words = cleaned.split(' ').take(6).joinToString(" ")
        return if (words.length <= MAX_TITLE_LENGTH) {
            words
        } else {
            words.substring(0, MAX_TITLE_LENGTH).trimEnd { it == ' ' || it == ',' } + "\u2026"
        }
    }

    /**
     * Strip common wrappers and prefixes an LLM might add (quotes,
     * leading "Title:", trailing period) and cap at
     * [MAX_TITLE_LENGTH].
     */
    fun sanitize(raw: String): String {
        var text = raw.trim()
        if (text.isEmpty()) return ""

        val newline = text.indexOf('\n')
        if (newline >= 0) text = text.substring(0, newline).trim()

        val wrappers = charArrayOf('"', '\'', '`', '*', '\u201C', '\u201D', '\u2018', '\u2019')
        while (
            text.length > 2 &&
            wrappers.contains(text.first()) &&
            wrappers.contains(text.last())
        ) {
            text = text.substring(1, text.length - 1).trim()
        }

        for (prefix in listOf("Title:", "Name:", "Chat:")) {
            if (text.startsWith(prefix, ignoreCase = true)) {
                text = text.substring(prefix.length).trim()
            }
        }

        if (text.endsWith('.') && text.length <= 36 && !text.dropLast(1).contains('.')) {
            text = text.dropLast(1)
        }

        if (text.isEmpty()) return ""
        if (text.length <= MAX_TITLE_LENGTH) return text
        return text.take(MAX_TITLE_LENGTH - 1) + "\u2026"
    }
}
```

- [ ] **Step 2: Write the failing test**

File: `android/app/src/test/kotlin/app/roamsocket/android/ui/chats/ChatTitleGeneratorTest.kt`

```kotlin
package app.roamsocket.android.ui.chats

import app.roamsocket.core.chats.PersistedChatMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatTitleGeneratorTest {

    private fun userMsg(content: String) = PersistedChatMessage(
        id = "u1", role = PersistedChatMessage.Role.USER,
        content = content, timestampMillis = 0L,
    )

    // -- heuristic ----------------------------------------------------------

    @Test fun heuristicFirstSixWords() {
        assertEquals(
            "What is the difference between SSE and",
            ChatTitleGenerator.heuristic("What is the difference between SSE and WebSockets?"),
        )
    }

    @Test fun heuristicCapsAtMaxLength() {
        val long = "x".repeat(200)
        val out = ChatTitleGenerator.heuristic(long)
        assertTrue(out.length <= ChatTitleGenerator.MAX_TITLE_LENGTH)
        assertTrue(out.endsWith("\u2026"))
    }

    @Test fun heuristicEmptyReturnsEmpty() {
        assertEquals("", ChatTitleGenerator.heuristic(""))
        assertEquals("", ChatTitleGenerator.heuristic("    "))
    }

    // -- sanitize -----------------------------------------------------------

    @Test fun sanitizeStripsWrappingQuotes() {
        assertEquals("Hello", ChatTitleGenerator.sanitize("\"Hello\""))
        assertEquals("Hello", ChatTitleGenerator.sanitize("\u201CHello\u201D"))
    }

    @Test fun sanitizeStripsTitlePrefix() {
        assertEquals("Hello", ChatTitleGenerator.sanitize("Title: Hello"))
        assertEquals("Hello", ChatTitleGenerator.sanitize("name: Hello"))
    }

    @Test fun sanitizeStripsTrailingPeriod() {
        assertEquals("Hello", ChatTitleGenerator.sanitize("Hello."))
    }

    @Test fun sanitizeKeepsTrailingPeriodWhenMultiple() {
        // "v1.0." would lose the trailing period only if there's a
        // single '.' in the short string.
        assertEquals("v1.0.", ChatTitleGenerator.sanitize("v1.0."))
    }

    @Test fun sanitizeCapsLongTitles() {
        val long = "x".repeat(200)
        val out = ChatTitleGenerator.sanitize(long)
        assertTrue(out.length <= ChatTitleGenerator.MAX_TITLE_LENGTH)
    }

    @Test fun sanitizeEmptyReturnsEmpty() {
        assertEquals("", ChatTitleGenerator.sanitize(""))
    }
}
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `cd android && ./gradlew :app:test --tests "app.roamsocket.android.ui.chats.ChatTitleGeneratorTest"`
Expected: PASS (9 tests, 0 failures).

- [ ] **Step 4: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/app/src/main/kotlin/app/roamsocket/android/ui/chats/ChatTitleGenerator.kt \
        android/app/src/test/kotlin/app/roamsocket/android/ui/chats/ChatTitleGeneratorTest.kt
git commit -m "feat(android): add ChatTitleGenerator (lightweight-model + heuristic)

Suggests a short chat title by asking the user's linked lightweight
model via LightweightTaskRunner, falling back to the first-6-words
heuristic. The sanitize() helper strips quote wrappers, Title:/Name:
prefixes, and trailing periods; caps at 48 chars. Matches the iOS
Chats/ChatTitleGenerator.swift surface. Covered by 9 unit tests
covering both the heuristic and the sanitize transformations."
```

---

## Task 11: ChatViewModel integration

**Files:**
- Modify: `android/app/src/main/kotlin/app/roamsocket/android/ui/chat/ChatViewModel.kt`

**Interfaces:**
- Consumes: `ChatHistoryStore` (from Task 9), `AppContainer` (existing)
- Produces: `activeProject: StateFlow<ProjectItem?>`, `currentProjectName: StateFlow<String?>`, `loadProjectChat(...)`, `attachCurrentChatToProject(...)`, `renameActiveProjectChat(title)`, `deleteActiveProjectChat()`, and updates `saveMessages(...)` to route to project or global.

- [ ] **Step 1: Read the current `ChatViewModel.kt` skeleton**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
wc -l android/app/src/main/kotlin/app/roamsocket/android/ui/chat/ChatViewModel.kt
grep -n "saveMessages\|historyStore\|onCleared\|fun send" android/app/src/main/kotlin/app/roamsocket/android/ui/chat/ChatViewModel.kt
```

- [ ] **Step 2: Add imports + state**

Near the top of `ChatViewModel.kt`, add:

```kotlin
import app.roamsocket.core.projects.ProjectChatItem
import app.roamsocket.core.projects.ProjectItem
import app.roamsocket.core.providers.AIModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
```

- [ ] **Step 3: Add the new state and methods**

Inside the `ChatViewModel` class, add these:

```kotlin
    /** Currently-active project (resolved from ChatHistoryStore.activeProject). */
    val activeProject: StateFlow<ProjectItem?> = historyStore.activeProject

    /** Display name of the active project, or null. */
    val currentProjectName: StateFlow<String?> = activeProject
        .map { it?.name }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    /**
     * Hydrate the chat view with a project-scoped chat. Used when
     * the user opens a project chat from ProjectDetailScreen.
     *
     * Reads the existing global-chat load path in this file (the
     * code that takes a [PersistedChatMessage] list and converts it
     * into the view-model's [ChatMessage] state) and re-uses it for
     * the project messages. If the existing code is in a helper
     * like `hydrateFrom(persistedMessages: List<PersistedChatMessage>)`,
     * call it here; otherwise inline the same conversion.
     */
    fun loadProjectChat(project: ProjectItem, chat: ProjectChatItem) {
        historyStore.openProjectChatAsActive(project.id, chat.id)
        val messages = historyStore.projectChatMessages(project.id, chat.id)
        _messages.value = messages.map { /* convert to ChatMessage using the same code path as the global load */ }
        _selectedModel.value = historyStore.projectChatSelectedModel(project.id, chat.id)
            ?: _selectedModel.value
    }

    /** Copy the active global chat into [project]. No-op for incognito or non-active. */
    fun attachCurrentChatToProject(project: ProjectItem) {
        val id = _activeChatId.value ?: return
        historyStore.addChatToProject(id, project.id)
    }
```

Note: the `_messages` / `_selectedModel` / `_activeChatId` private state is whatever the existing view-model uses; mirror its naming. If the existing code uses different names (e.g. `messagesState`, `selectedModelState`), use those.

The exact hydration code depends on how the existing `ChatViewModel` exposes its state. **Read the file first** (Step 1) and adjust this snippet to match the existing field names and converters. The behavior must be: load the messages into the chat UI state, set the selected model, and remember the project context for subsequent `saveMessages` calls.

- [ ] **Step 4: Update `saveMessages` to route to project or global**

Find the existing `saveMessages(...)` method in `ChatViewModel`. After it persists via `historyStore.saveMessages(...)`, add a branch that also persists to the project when an active project is set:

```kotlin
    private fun persistMessages(messages: List<PersistedChatMessage>) {
        val activeProject = historyStore.activeProject.value
        if (activeProject != null) {
            val chatId = _activeChatId.value ?: return
            historyStore.saveProjectChatMessages(activeProject.id, chatId, messages)
        } else {
            val chatId = _activeChatId.value ?: return
            historyStore.saveMessages(chatId, messages)
        }
    }
```

Then call `persistMessages(...)` from the existing save point (replacing the previous `historyStore.saveMessages(...)` call). If the existing code calls `historyStore.saveMessages` in multiple places, route every call through `persistMessages`.

- [ ] **Step 5: Add inline rename + delete for project chats**

Add to `ChatViewModel`:

```kotlin
    fun renameActiveProjectChat(newTitle: String) {
        val project = historyStore.activeProject.value ?: return
        val chatId = _activeChatId.value ?: return
        historyStore.renameProjectChat(project.id, chatId, newTitle)
    }

    fun deleteActiveProjectChat() {
        val project = historyStore.activeProject.value ?: return
        val chatId = _activeChatId.value ?: return
        historyStore.deleteProjectChat(project.id, chatId)
    }
```

- [ ] **Step 6: Verify it compiles**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 7: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/app/src/main/kotlin/app/roamsocket/android/ui/chat/ChatViewModel.kt
git commit -m "feat(android): ChatViewModel loads/saves project chats

Adds activeProject + currentProjectName flows, loadProjectChat,
attachCurrentChatToProject, renameActiveProjectChat,
deleteActiveProjectChat. saveMessages now routes through
persistMessages() so it writes to the project-scoped store when an
active project is set, otherwise to the global ChatHistoryStore.
The chat UI is now project-aware."
```

---

## Task 12: UI — ProjectsListScreen + CreateProjectSheet + navigation wire-up

**Files:**
- Create: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsViewModel.kt`
- Create: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsListScreen.kt`
- Create: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/CreateProjectSheet.kt`
- Modify: `android/app/src/main/kotlin/app/roamsocket/android/ui/RootView.kt`

**Interfaces:**
- Consumes: `ChatHistoryStore` (from Task 9)
- Produces: `ProjectsListScreen` (search + FAB + empty state), `CreateProjectSheet` (name entry), `RootView` routes `SidebarDestination.Projects` → list.

- [ ] **Step 1: Create the lightweight VM**

File: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsViewModel.kt`

```kotlin
package app.roamsocket.android.ui.projects

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import app.roamsocket.android.ui.LocalAppContainer
import app.roamsocket.android.ui.sidebar.ChatHistoryStore
import app.roamsocket.android.ui.sidebar.rememberChatHistoryStore
import app.roamsocket.core.projects.ProjectItem
import kotlinx.coroutines.flow.StateFlow

/**
 * Lightweight VM for the Projects list + detail screens. Just
 * exposes a `StateFlow<List<ProjectItem>>` and the coordinator
 * methods they need. Heavy logic (active project resolution,
 * cross-store coordination) lives in [ChatHistoryStore].
 */
@Immutable
data class ProjectsViewModel(
    val historyStore: ChatHistoryStore,
) {
    val projects: StateFlow<List<ProjectItem>> = historyStore.projects

    fun createProject(name: String): ProjectItem = historyStore.createProject(name)
}

@Composable
fun rememberProjectsViewModel(): ProjectsViewModel {
    val historyStore = rememberChatHistoryStore()
    return remember(historyStore) { ProjectsViewModel(historyStore) }
}

@Composable
fun collectProjects(): List<ProjectItem> {
    val vm = rememberProjectsViewModel()
    val projects by vm.projects.collectAsState()
    return projects
}
```

- [ ] **Step 2: Create `CreateProjectSheet.kt`**

File: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/CreateProjectSheet.kt`

```kotlin
package app.roamsocket.android.ui.projects

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Minimal "new project" sheet: name + optional description. Mirrors
 * iOS `Sidebar/CreateProjectSheet.swift`. Project description is
 * accepted but not yet persisted (iOS stores it in the project
 * data; for Phase 1 we keep just the name).
 */
@Composable
fun CreateProjectSheet(
    onCreate: (name: String, description: String) -> Unit,
    onCancel: () -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("New project") },
        text = {
            Column(modifier = Modifier.fillMaxWidth()) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it.take(80) },
                    label = { Text("Name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(modifier = Modifier.height(12.dp))
                OutlinedTextField(
                    value = description,
                    onValueChange = { description = it.take(280) },
                    label = { Text("Description (optional)") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    val trimmed = name.trim()
                    if (trimmed.isNotEmpty()) onCreate(trimmed, description.trim())
                },
                enabled = name.isNotBlank(),
            ) { Text("Create") }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}
```

- [ ] **Step 3: Create `ProjectsListScreen.kt`**

File: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsListScreen.kt`

```kotlin
package app.roamsocket.android.ui.projects

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.AutoMirrored
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.roamsocket.android.ui.LocalOpenSidebar
import app.roamsocket.android.ui.placeholder.PlaceholderScreen
import app.roamsocket.core.projects.ProjectItem

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectsListScreen(
    onBack: () -> Unit,
    onOpenProject: (projectId: String) -> Unit,
) {
    val openSidebar = LocalOpenSidebar.current
    val viewModel = rememberProjectsViewModel()
    val projects by viewModel.projects.collectAsState()
    var query by remember { mutableStateOf("") }
    var showCreate by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Projects") },
                navigationIcon = {
                    IconButton(onClick = openSidebar) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Outlined.MenuBook,
                            contentDescription = "Menu",
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                ),
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = { showCreate = true },
                containerColor = MaterialTheme.colorScheme.primary,
            ) { Icon(Icons.Outlined.Add, contentDescription = "New project") }
        },
    ) { innerPadding ->
        if (projects.isEmpty() && query.isEmpty()) {
            EmptyProjectsState(modifier = Modifier.padding(innerPadding))
        } else {
            val filtered = projects.filter { p ->
                query.isEmpty() || p.name.contains(query, ignoreCase = true)
            }
            Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                    placeholder = { Text("Search") },
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                )
                LazyColumn(
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(filtered, key = { it.id }) { project ->
                        ProjectRow(project = project, onClick = { onOpenProject(project.id) })
                    }
                }
            }
        }
    }

    if (showCreate) {
        CreateProjectSheet(
            onCreate = { name, _ ->
                viewModel.createProject(name)
                showCreate = false
            },
            onCancel = { showCreate = false },
        )
    }
}

@Composable
private fun ProjectRow(project: ProjectItem, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 1.dp,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = project.name,
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = "Updated ${relativeTime(project.updatedAtMillis)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun EmptyProjectsState(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = Icons.Outlined.Search, // placeholder; replace with tray icon
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.height(48.dp),
        )
        Text(
            text = "No projects yet",
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = "Create a project to organize chats.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

private fun relativeTime(millis: Long): String {
    val diff = System.currentTimeMillis() - millis
    val sec = diff / 1000
    return when {
        sec < 60 -> "just now"
        sec < 3600 -> "${sec / 60}m ago"
        sec < 86400 -> "${sec / 3600}h ago"
        else -> "${sec / 86400}d ago"
    }
}

@Composable
private fun IconButton(onClick: () -> Unit, content: @Composable () -> Unit) {
    androidx.compose.material3.IconButton(onClick = onClick) { content() }
}
```

- [ ] **Step 4: Wire it up in `RootView.kt`**

1. Add the import at the top of `RootView.kt`:
   ```kotlin
   import app.roamsocket.android.ui.projects.ProjectsListScreen
   ```
2. In the `when (current) { ... }` block, replace the `SidebarDestination.Projects` placeholder branch with a real one. Add a `projectsSubDest` state and route:
   ```kotlin
   var projectsSubDest by remember { mutableStateOf<ProjectsSubDest?>(null) }
   // ...
   SidebarDestination.Projects -> {
       when (val sub = projectsSubDest) {
           is ProjectsSubDest.Detail -> ProjectDetailScreen(
               projectId = sub.id,
               onBack = { projectsSubDest = null },
               onOpenChat = {
                   projectsSubDest = null
                   current = SidebarDestination.Chats
               },
           )
           null -> ProjectsListScreen(
               onBack = { current = SidebarDestination.Chats },
               onOpenProject = { id -> projectsSubDest = ProjectsSubDest.Detail(id) },
           )
       }
   }
   ```
3. Also clear `projectsSubDest` in the existing `navigate(to:)` helper (alongside the other sub-dest clears).
4. Define `private sealed class ProjectsSubDest { data class Detail(val id: String) : ProjectsSubDest() }` near the other sub-dest sealed classes at the top of `RootView.kt`.

Note: `ProjectDetailScreen` is implemented in Task 13. The import is added in that task; here, just reference the function name and let the compiler error drive Task 13.

- [ ] **Step 5: Verify it compiles**

Run: `cd android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL (after Task 13 lands; for now expect an "unresolved reference: ProjectDetailScreen" — that's fine, suppress with a stub if needed, or do Task 13 first).

To unblock intermediate builds, temporarily add a no-op `ProjectDetailScreen` stub in `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectDetailScreen.kt` (a `PlaceholderScreen` call). Replace it in Task 13.

- [ ] **Step 6: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsViewModel.kt \
        android/app/src/main/kotlin/app/roamsocket/android/ui/projects/CreateProjectSheet.kt \
        android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsListScreen.kt \
        android/app/src/main/kotlin/app/roamsocket/android/ui/RootView.kt
git commit -m "feat(android): add Projects list + create sheet + sidebar wiring

ProjectsListScreen (search + FAB + empty state), CreateProjectSheet
(name + optional description), lightweight ProjectsViewModel that
re-exposes the coordinator surface. RootView routes
SidebarDestination.Projects to the list, with a projectsSubDest that
navigates to a (stub) ProjectDetailScreen for the next task. Uses
existing theme tokens — no new palette."
```

---

## Task 13: UI — ProjectDetailScreen + Instruction + Memory sheets

**Files:**
- Create: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectDetailScreen.kt`
- Create: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectInstructionsSheet.kt`
- Create: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectMemorySheet.kt`
- Modify: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsViewModel.kt` (add `loadProject(id)` returning a `ProjectItem?` derived from `projects.firstOrNull { it.id == id }`)

- [ ] **Step 1: Add a `loadProject` helper to `ProjectsViewModel`**

In `ProjectsViewModel.kt`, add:

```kotlin
    fun loadProject(id: String): ProjectItem? =
        historyStore.projects.value.firstOrNull { it.id == id }
```

- [ ] **Step 2: Create `ProjectInstructionsSheet.kt`**

File: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectInstructionsSheet.kt`

```kotlin
package app.roamsocket.android.ui.projects

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectInstructionsSheet(
    projectName: String,
    initialText: String,
    onSave: (String) -> Unit,
    onCancel: () -> Unit,
) {
    var text by remember { mutableStateOf(initialText) }
    androidx.compose.material3.ModalBottomSheet(onDismissRequest = onCancel) {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            Row {
                Text(
                    "Set project instructions",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onCancel) {
                    Icon(Icons.Outlined.Close, contentDescription = "Close")
                }
            }
            Text(
                "Provide relevant instructions for chats within $projectName. Works alongside profile instructions and the selected style.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 4.dp),
            )
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                placeholder = { Text("Think step by step and show reasoning for complex problems. Use specific examples.") },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(180.dp)
                    .padding(vertical = 8.dp),
            )
            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                TextButton(onClick = onCancel, modifier = Modifier.weight(1f)) { Text("Cancel") }
                TextButton(
                    onClick = { onSave(text.trim()) },
                    modifier = Modifier.weight(1f),
                ) { Text("Save instructions") }
            }
        }
    }
}
```

- [ ] **Step 3: Create `ProjectMemorySheet.kt`**

File: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectMemorySheet.kt`

```kotlin
package app.roamsocket.android.ui.projects

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowForward
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectMemorySheet(
    projectName: String,
    initialMemory: String,
    onSave: (String) -> Unit,
    onCommand: (String) -> String,
    onCancel: () -> Unit,
) {
    var memory by remember { mutableStateOf(initialMemory) }
    var command by remember { mutableStateOf("") }
    androidx.compose.material3.ModalBottomSheet(onDismissRequest = onCancel) {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            Row {
                Text(
                    "Manage project memory",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onCancel) {
                    Icon(Icons.Outlined.Close, contentDescription = "Close")
                }
            }
            Text(
                "Memory is private on this device. Use the field below to forget or remember facts for $projectName. Try \"remember I like coffee\" or \"forget coffee\".",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 4.dp),
            )
            OutlinedTextField(
                value = memory,
                onValueChange = { memory = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(160.dp)
                    .padding(vertical = 8.dp),
            )
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = command,
                    onValueChange = { command = it },
                    placeholder = { Text("remember I like coffee") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                IconButton(
                    onClick = {
                        val next = onCommand(command.trim())
                        memory = next
                        command = ""
                    },
                    enabled = command.isNotBlank(),
                ) { Icon(Icons.Outlined.ArrowForward, contentDescription = "Apply") }
            }
            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                TextButton(onClick = onCancel, modifier = Modifier.weight(1f)) { Text("Cancel") }
                TextButton(
                    onClick = { onSave(memory) },
                    modifier = Modifier.weight(1f),
                ) { Text("Save") }
            }
        }
    }
}
```

- [ ] **Step 4: Create `ProjectDetailScreen.kt`**

File: `android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectDetailScreen.kt`

```kotlin
package app.roamsocket.android.ui.projects

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.roamsocket.android.ui.LocalNavigateToCode
import app.roamsocket.android.ui.LocalOpenSidebar
import app.roamsocket.android.ui.placeholder.PlaceholderScreen
import app.roamsocket.core.projects.ProjectChatItem
import app.roamsocket.core.projects.ProjectItem

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectDetailScreen(
    projectId: String,
    onBack: () -> Unit,
    /** Called when the user wants to open a project chat. The host
     *  (RootView) navigates to [SidebarDestination.Chats]; the
     *  active project + chat are already set on the coordinator. */
    onOpenChat: () -> Unit,
) {
    val openSidebar = LocalOpenSidebar.current
    val viewModel = rememberProjectsViewModel()
    val projects by viewModel.projects.collectAsState()
    val chats by viewModel.historyStore.projectChats.collectAsState()

    val project = projects.firstOrNull { it.id == projectId }
    if (project == null) {
        // Project was deleted while open — fall back to the list.
        onBack()
        return
    }

    val projectChats = chats[projectId].orEmpty()
        .filter { !it.isArchived && it.messages.isNotEmpty() }

    var showInstructions by remember { mutableStateOf(false) }
    var showMemory by remember { mutableStateOf(false) }
    var renameTarget by remember { mutableStateOf<ProjectChatItem?>(null) }
    var deleteTarget by remember { mutableStateOf<ProjectChatItem?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(project.name) },
                navigationIcon = {
                    IconButton(onClick = openSidebar) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Outlined.MenuBook,
                            contentDescription = "Menu",
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                ),
            )
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = {
                    val newChat = viewModel.historyStore.startNewChatInProject(project)
                    viewModel.historyStore.setActiveProject(project.id)
                    onOpenChat()
                },
                icon = { Icon(Icons.Outlined.Add, contentDescription = null) },
                text = { Text("New chat") },
            )
        },
    ) { innerPadding ->
        Column(modifier = Modifier.padding(innerPadding).fillMaxSize()) {
            InstructionPill(
                text = if (project.instructions.isBlank()) "Set project instructions" else "Edit project instructions",
                onClick = { showInstructions = true },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            )
            MemoryBanner(
                preview = project.memory,
                updatedAtMillis = project.memoryUpdatedAtMillis,
                onClick = { showMemory = true },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
            )
            if (projectChats.isEmpty()) {
                EmptyChatsState(modifier = Modifier.fillMaxSize().padding(32.dp))
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(projectChats, key = { it.id }) { chat ->
                        ProjectChatRow(
                            chat = chat,
                            onClick = {
                                viewModel.historyStore.setActiveProject(project.id)
                                // Mark this chat id as active on the chat-history
                                // repository so ChatViewModel.loadProjectChat can
                                // resolve it; ChatScreen will hydrate from the
                                // project's chat store via persistMessages' active
                                // project branch.
                                viewModel.historyStore.openProjectChatAsActive(project.id, chat.id)
                                onOpenChat()
                            },
                            onRename = { renameTarget = chat },
                            onDelete = { deleteTarget = chat },
                        )
                    }
                }
            }
        }
    }

    if (showInstructions) {
        ProjectInstructionsSheet(
            projectName = project.name,
            initialText = project.instructions,
            onSave = {
                viewModel.historyStore.updateProjectInstructions(project.id, it)
                showInstructions = false
            },
            onCancel = { showInstructions = false },
        )
    }

    if (showMemory) {
        ProjectMemorySheet(
            projectName = project.name,
            initialMemory = project.memory,
            onSave = {
                viewModel.historyStore.updateProjectMemory(project.id, it)
                showMemory = false
            },
            onCommand = { cmd -> viewModel.historyStore.applyProjectMemoryCommand(project.id, cmd) },
            onCancel = { showMemory = false },
        )
    }

    renameTarget?.let { chat ->
        InlineRenameDialog(
            initial = chat.title,
            onConfirm = { newTitle ->
                viewModel.historyStore.renameProjectChat(project.id, chat.id, newTitle)
                renameTarget = null
            },
            onCancel = { renameTarget = null },
        )
    }

    deleteTarget?.let { chat ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete chat?") },
            text = { Text("This will remove the chat from the project. The original global copy (if any) is unaffected.") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.historyStore.deleteProjectChat(project.id, chat.id)
                    deleteTarget = null
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun InstructionPill(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 1.dp,
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun MemoryBanner(
    preview: String,
    updatedAtMillis: Long?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 1.dp,
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick),
    ) {
        Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Memory",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    "Only you",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Icon(
                    Icons.Outlined.Edit,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 4.dp).size(14.dp),
                )
            }
            Text(
                if (preview.isBlank()) "No memory yet — try \"remember I like coffee\"."
                else preview,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )
            if (updatedAtMillis != null) {
                Text(
                    "Last updated ${relativeTime(updatedAtMillis)}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun ProjectChatRow(
    chat: ProjectChatItem,
    onClick: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 1.dp,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(chat.title, style = MaterialTheme.typography.bodyLarge)
                Text(
                    relativeTime(chat.lastMessageAtMillis),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            IconButton(onClick = onRename) {
                Icon(Icons.Outlined.Edit, contentDescription = "Rename", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = onDelete) {
                Icon(Icons.Outlined.Delete, contentDescription = "Delete", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun EmptyChatsState(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            "No chats yet",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            "Tap New chat to start a conversation in this project.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun InlineRenameDialog(
    initial: String,
    onConfirm: (String) -> Unit,
    onCancel: () -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("Rename chat") },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it.take(80) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(text.trim()) },
                enabled = text.isNotBlank(),
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}

private fun relativeTime(millis: Long): String {
    val diff = System.currentTimeMillis() - millis
    val sec = diff / 1000
    return when {
        sec < 60 -> "just now"
        sec < 3600 -> "${sec / 60}m ago"
        sec < 86400 -> "${sec / 3600}h ago"
        else -> "${sec / 86400}d ago"
    }
}
```

- [ ] **Step 5: Verify it compiles + builds**

Run: `cd android && ./gradlew :app:compileDebugKotlin && cd android && ./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectsViewModel.kt \
        android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectDetailScreen.kt \
        android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectInstructionsSheet.kt \
        android/app/src/main/kotlin/app/roamsocket/android/ui/projects/ProjectMemorySheet.kt
git commit -m "feat(android): add ProjectDetailScreen + Instructions + Memory sheets

ProjectDetailScreen renders the instruction pill, memory banner, and
chats list. ProjectInstructionsSheet and ProjectMemorySheet mirror
the iOS SwiftUI sheets: memory supports forget/remember commands
delivered through MemoryCommandParser. Includes an inline rename
dialog and a delete confirmation. Uses existing theme tokens."
```

---

## Task 14: UI — AddToChatSheet real project picker

**Files:**
- Modify: `android/app/src/main/kotlin/app/roamsocket/android/ui/chat/AddToChatSheet.kt`
- Modify: `android/app/src/main/kotlin/app/roamsocket/android/ui/chat/ChatScreen.kt`

- [ ] **Step 1: Read the current `AddToChatSheet` signature and the `onAddToProject` callback**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
grep -n "onAddToProject\|onShowConnectors\|AddToChatSheet(" android/app/src/main/kotlin/app/roamsocket/android/ui/chat/AddToChatSheet.kt
grep -n "onAddToProject\|onAttachToProject" android/app/src/main/kotlin/app/roamsocket/android/ui/chat/ChatScreen.kt
```

- [ ] **Step 2: Add a project picker section to `AddToChatSheet.kt`**

The existing sheet has an "Add to project" row that calls `onAddToProject()`. Replace that single callback with two callbacks the host can wire:

```kotlin
fun AddToChatSheet(
    // ... existing params ...
    /** The user's projects (already collected by the host). */
    projects: List<ProjectItem>,
    /** The currently-active project, or null. */
    currentProject: ProjectItem?,
    onPickProject: (ProjectItem) -> Unit,
    onCreateProjectAndAttach: (name: String) -> Unit,
)
```

Inside the sheet body, replace the existing "Add to project" row with a `ProjectPickerSection` that:
1. Shows the current project's name (or "None") on the row trailing position.
2. Tapping the row expands an inline section listing all projects.
3. Tapping a project calls `onPickProject(project)`.
4. Tapping "New project…" reveals a small text field + Create/Cancel; on Create, calls `onCreateProjectAndAttach(name)`.

The picker stays in the same sheet (no nested navigation). Use `var expanded by remember { mutableStateOf(false) }` for the expand/collapse state and `var newName by remember { mutableStateOf("") }` for the inline create field. After Create, dismiss the sheet via `onDismiss` (caller's responsibility) or by clearing local state.

- [ ] **Step 3: Wire it in `ChatScreen.kt`**

In the call site (around line 273 in the current file), replace the existing `onAddToProject = { navigateToSidebar(...) }` block with:

```kotlin
val projects by rememberProjectsViewModel().projects.collectAsState()
val currentProject by viewModel.currentProjectName.collectAsState()  // ← already added in Task 11
val activeProject by viewModel.activeProject.collectAsState()

// ...

if (showAddToChat) {
    AddToChatSheet(
        // ... existing params ...
        projects = projects,
        currentProject = activeProject,
        onPickProject = { project ->
            viewModel.attachCurrentChatToProject(project)
            showAddToChat = false
        },
        onCreateProjectAndAttach = { name ->
            val newProject = historyStore.createProject(name)
            viewModel.attachCurrentChatToProject(newProject)
            showAddToChat = false
        },
    )
}
```

Add the necessary imports:
```kotlin
import app.roamsocket.android.ui.projects.rememberProjectsViewModel
import app.roamsocket.core.projects.ProjectItem
```

- [ ] **Step 4: Verify it compiles + builds**

Run: `cd android && ./gradlew :app:compileDebugKotlin && cd android && ./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git add android/app/src/main/kotlin/app/roamsocket/android/ui/chat/AddToChatSheet.kt \
        android/app/src/main/kotlin/app/roamsocket/android/ui/chat/ChatScreen.kt
git commit -m "feat(android): replace AddToChat 'Add to project' with real picker

The 'Add to project' row in AddToChatSheet now opens an inline picker
listing the user's projects plus a 'New project…' create field. The
host (ChatScreen) wires the picker to ChatHistoryStore +
ChatViewModel.attachCurrentChatToProject, replacing the previous
shortcut that jumped to the sidebar placeholder."
```

---

## Task 15: Final verification + PR

**Files:** (no code changes; verification only)

- [ ] **Step 1: Run all data-layer tests**

Run: `cd android && ./gradlew :RoamSocketCore:test`
Expected: BUILD SUCCESSFUL. All projects + chats + protocol + server + provider + code + github tests pass. New project tests: 26 (12 + 4 + 10), MemoryCommandParserTest 10, ProjectSchemaTest 3, total 39 new tests.

- [ ] **Step 2: Run all app tests**

Run: `cd android && ./gradlew :app:test`
Expected: BUILD SUCCESSFUL. New tests: DataStoreProjectRepositoryTest 2, ChatTitleGeneratorTest 9, total 11 new app tests.

- [ ] **Step 3: Build the debug APK**

Run: `cd android && ./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL with no new warnings.

- [ ] **Step 4: Manual smoke checklist**

Walk through the user flow on a connected device or emulator (a fresh install is best):

- [ ] Open the sidebar → tap Projects → no PlaceholderScreen; the list opens
- [ ] No projects yet → empty state with "Create a project" FAB
- [ ] Tap FAB → "New project" sheet appears
- [ ] Type a name, tap Create → returns to the list; new project is at the top
- [ ] Tap the new project → detail screen opens with the Instructions pill + Memory banner
- [ ] Tap Instructions pill → sheet opens; type "Think step by step"; Save → returns to detail; pill still says "Edit project instructions"
- [ ] Tap Memory banner → sheet opens; in the command field type "remember I like coffee" → tap the apply arrow → the memory text now contains "• I like coffee"
- [ ] In the Memory sheet, type "forget coffee" → apply → bullet removed
- [ ] Save memory → returns to detail; memory banner shows the saved text
- [ ] Tap "New chat" on the project → a blank chat is created in the project; (TODO: load it in the chat view — confirm this works or note the gap)
- [ ] From a global chat: tap the + button → "Add to project" → inline picker shows your project → tap it → chat is added to the project's chats list
- [ ] In the project detail, tap a chat's rename icon → inline dialog → rename → name updates
- [ ] Tap a chat's delete icon → confirm → chat disappears from the list
- [ ] Kill the app, relaunch → project + instructions + memory + chats all persist

If the "load project chat in the chat view" TODO from Task 13 doesn't fully wire up yet, **file it as a known follow-up** but don't block the PR — the data layer + screen surface are all functional. The chat view can open the project chat in a follow-up commit within the same PR.

- [ ] **Step 5: Push and open the PR**

```bash
cd /Users/jc/Projects/roamsocket-mobile/.worktrees/feat-auto-20260827-44d68f97
git push -u origin feat/android-projects
gh pr create --base main \
    --title "feat(android): port Projects feature from iOS" \
    --body "Port of the iOS Projects feature to Android with full functional parity. See docs/superpowers/specs/2026-08-27-android-projects-design.md for the design.

Data layer:
- New RoamSocketCore/projects/ package (ProjectItem, ProjectChatItem, ProjectRepository, InMemoryProjectRepository, MemoryCommandParser)
- New app/data/DataStoreProjectRepository (single JSON blob, mirrors InMemory to DataStore)
- 39 new JVM unit tests in RoamSocketCore covering schema, memory command parser, in-memory repo (CRUD + addChatToProject + chat lifecycle), plus the JSON round-trip
- 11 new app tests covering DataStore persistence (Robolectric) and ChatTitleGenerator

UI:
- ProjectsListScreen (search + FAB + empty state)
- ProjectDetailScreen (Instructions pill, Memory banner, chats list)
- CreateProjectSheet, ProjectInstructionsSheet, ProjectMemorySheet
- AddToChatSheet now has a real project picker (replaces the placeholder shortcut)
- ChatViewModel is project-aware: saveMessages routes to project or global, attachCurrentChatToProject wires the picker
- ChatTitleGenerator uses LightweightTaskRunner for LLM-driven chat titles (with heuristic fallback) — the user-requested change

Verification:
- :RoamSocketCore:test passes (39 new tests)
- :app:test passes (11 new tests)
- assembleDebug builds clean

Out of scope (filed for follow-up):
- deleteProject (iOS doesn't have it either)
- Project chat swipe actions
- on-device Foundation Model titles (iOS-only; Android uses the linked lightweight model instead)"
```

- [ ] **Step 6: Stop and wait for review**

Once the PR is open, stop and report. The user reviews and merges.
