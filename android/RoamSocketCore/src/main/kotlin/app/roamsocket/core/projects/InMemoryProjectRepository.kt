package app.roamsocket.core.projects

import app.roamsocket.core.chats.ChatHistoryItem
import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/**
 * Default in-memory implementation of [ProjectRepository]. All
 * mutations flow through a `mutateProjects {}` / `mutateChats {}`
 * helper so the public [projects] / [projectChats] /
 * [activeProjectId] flows stay in lock-step with the source lists.
 * The Android app module wraps this with DataStore-backed
 * persistence.
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

    // -- chat-in-project -----------------------------------------------------

    override fun addChatToProject(source: ChatHistoryItem, projectID: String): ProjectChatItem? {
        if (source.isIncognito) return null
        if (_projects.value.none { it.id == projectID }) return null

        // The Android `ChatHistoryItem` doesn't carry iOS's title-edit
        // bookkeeping fields (titleIsUserEdited / didAutoTitle /
        // autoTitleAtUserCount) — they live in the iOS Codable only.
        // The Android port resets these on copy: the project copy
        // starts from a fresh auto-title state and the user can edit
        // independently. A future cross-port normalization will sync
        // the fields once `ChatHistoryItem` carries them.
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
            titleIsUserEdited = false,
            didAutoTitle = false,
            autoTitleAtUserCount = 0,
        )
        mutateChats { map ->
            val list = map[projectID]?.toMutableList() ?: mutableListOf()
            list.add(0, newChat)
            map[projectID] = list
        }
        bumpProjectUpdatedAt(projectID)
        return newChat
    }

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
            map[projectID] = list
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
            map[projectID] = list
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
            map[projectID] = list
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
            map[projectID] = list
        }
    }

    // -- pruning / persistence ----------------------------------------------

    override fun pruneBlankProjectDrafts() {
        mutateChats { map ->
            for ((projectID, list) in map.toMap()) {
                val filtered = list.filter { it.messages.isNotEmpty() }
                if (filtered.size != list.size) {
                    map[projectID] = filtered
                }
            }
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

    private fun bumpProjectUpdatedAt(projectID: String) {
        mutateProjects { list ->
            val idx = list.indexOfFirst { it.id == projectID }
            if (idx >= 0) {
                list[idx] = list[idx].copy(updatedAtMillis = System.currentTimeMillis())
            }
        }
    }

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

    private fun newID(): String = UUID.randomUUID().toString()
}
