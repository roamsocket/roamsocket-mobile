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
