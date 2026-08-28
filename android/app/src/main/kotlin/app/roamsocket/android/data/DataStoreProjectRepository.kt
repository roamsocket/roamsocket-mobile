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
        return try {
            json.decodeFromString(ProjectsStateSnapshot.serializer(), raw)
        } catch (e: Throwable) {
            emptySnapshot()
        }
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
