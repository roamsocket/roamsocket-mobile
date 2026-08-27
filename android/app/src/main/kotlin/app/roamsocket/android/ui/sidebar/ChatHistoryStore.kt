package app.roamsocket.android.ui.sidebar

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import app.roamsocket.android.AppContainer
import app.roamsocket.android.ui.LocalAppContainer
import app.roamsocket.core.chats.ChatHistoryItem as CoreChatHistoryItem
import app.roamsocket.core.chats.ChatHistoryRepository
import app.roamsocket.core.chats.IncognitoLifetime
import app.roamsocket.core.chats.PersistedChatMessage
import app.roamsocket.core.projects.ProjectChatItem
import app.roamsocket.core.projects.ProjectItem
import app.roamsocket.core.projects.ProjectRepository
import app.roamsocket.core.providers.AIModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * One row in the sidebar's "Recents" list. This is a *display* model
 * derived from the persisted [CoreChatHistoryItem]; the canonical record
 * lives in `RoamSocketCore` and is JSON-serialisable. The sidebar type
 * stays here because it carries rendering hints (`isStarred`, `isToolCall`)
 * that don't need to be persisted as-is.
 */
@Immutable
data class ChatHistoryItem(
    val id: String,
    val title: String,
    val isStarred: Boolean = false,
    val isIncognito: Boolean = false,
    /** Rendered as a chat bubble glyph. Reserved for the tool-call UI. */
    val isToolCall: Boolean = true,
    val updatedAtMillis: Long = System.currentTimeMillis(),
)

/**
 * Thin Compose-facing wrapper over [ChatHistoryRepository]. The
 * repository holds the source of truth (persisted in DataStore); this
 * class only re-publishes the recents list as a [StateFlow] and maps
 * persisted rows into the sidebar's display [ChatHistoryItem].
 *
 * Both the sidebar's `Recents` list and the `ChatViewModel` share the
 * same repository instance via the `AppContainer`.
 */
class ChatHistoryStore internal constructor(
    private val repository: ChatHistoryRepository,
    private val projectRepository: ProjectRepository,
    /** Long-lived scope for the recents mirror collector. */
    private val flowScope: CoroutineScope,
) {
    private val _recents = MutableStateFlow<List<ChatHistoryItem>>(emptyList())
    val recents: StateFlow<List<ChatHistoryItem>> = _recents.asStateFlow()

    init {
        // Keep the sidebar's recents in lock-step with the repository.
        // The collector is owned by the process-scoped flowScope, so it
        // runs for the lifetime of the app.
        flowScope.launch {
            repository.recents.collect { persisted ->
                _recents.value = persisted.map(::toDisplayItem)
            }
        }
    }

    /** Newest-first — matches what iOS renders in the Recents section. */
    val activeRecents: List<ChatHistoryItem>
        get() = _recents.value

    /**
     * Add a new chat to the top of the list and return it. Backed by the
     * repository; the blank draft is hidden from `recents` until the
     * first message lands.
     */
    fun touch(title: String): ChatHistoryItem {
        // If a chat with this title already exists, open it (parity with
        // the iOS convenience path used by `MessageActionsSheet`).
        val existing = repository.recents.value.firstOrNull { it.title == title }
        if (existing != null) {
            repository.openChat(existing.id)
            return toDisplayItem(existing)
        }
        val id = repository.startNewChat()
        return ChatHistoryItem(
            id = id,
            title = title,
            updatedAtMillis = System.currentTimeMillis(),
        )
    }

    fun rename(id: String, title: String) {
        // Title mutation isn't in the repository yet (the iOS rename
        // sheet uses on-device LLM titles in some flows). For now we
        // mirror the in-memory sidebar update so the UI stays in sync.
        _recents.value = _recents.value.map { if (it.id == id) it.copy(title = title) else it }
    }

    fun setStarred(id: String, starred: Boolean) {
        _recents.value = _recents.value.map { if (it.id == id) it.copy(isStarred = starred) else it }
    }

    fun delete(id: String) {
        repository.deleteChat(id)
    }

    fun archive(id: String) = delete(id)

    fun forgetChatNow(id: String) = delete(id)

    // -- Project coordinator -------------------------------------------------

    val projects: StateFlow<List<ProjectItem>> = projectRepository.projects
    val projectChats: StateFlow<Map<String, List<ProjectChatItem>>> = projectRepository.projectChats
    val activeProjectId: StateFlow<String?> = projectRepository.activeProjectId

    /** The currently-active project (resolved from [activeProjectId]). */
    val activeProject: StateFlow<ProjectItem?> = combine(
        projectRepository.projects,
        projectRepository.activeProjectId,
    ) { list, id -> list.firstOrNull { it.id == id } }
        .stateIn(flowScope, SharingStarted.Eagerly, null)

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

    /**
     * Persist the current message list for a chat. Used by the chat
     * view-model after every send/receive so the transcript survives an
     * app restart.
     */
    fun saveMessages(id: String, messages: List<PersistedChatMessage>) {
        repository.saveMessages(id, messages)
    }

    /** Open a previously-saved chat (sidebar recent tap). */
    fun openChat(id: String) {
        repository.openChat(id)
    }

    /** Forget the active chat if it has no messages. */
    fun discardActiveIfBlank() {
        repository.discardActiveIfBlank()
    }

    /** Start a new blank chat. Returns the new id. */
    fun startNewChat(): String = repository.startNewChat()

    /**
     * Start a new blank incognito chat with the chosen forget schedule.
     * Mirrors `ios/.../ChatHistoryStore.startIncognitoChat(...)`. The
     * new chat becomes the active one and appears in Recents (with the
     * incognito dot) until the user exits or its `forgetAtMillis`
     * deadline passes.
     */
    fun startIncognitoChat(lifetime: IncognitoLifetime): String =
        repository.startIncognitoChat(lifetime)

    /**
     * Change the forget schedule of an existing incognito chat. No-op
     * for regular chats.
     */
    fun setIncognitoLifetime(id: String, lifetime: IncognitoLifetime) =
        repository.setIncognitoLifetime(id, lifetime)

    /**
     * Immediately drop the active chat if it is an `ON_EXIT` incognito
     * chat. The host calls this when the user navigates away from a
     * chat (or the activity is paused), so the transcript dies on
     * schedule. No-op for regular chats and for timed incognito chats.
     */
    fun forgetActiveIfOnExit() = repository.forgetActiveIfOnExit()

    /**
     * Walk the persisted list and drop every incognito chat whose
     * `forgetAtMillis` has passed. Called once at app startup so the
     * user doesn't see zombie incognito rows from yesterday.
     */
    fun pruneExpiredIncognito(): List<String> = repository.pruneExpiredIncognito()
}

private fun toDisplayItem(p: CoreChatHistoryItem): ChatHistoryItem = ChatHistoryItem(
    id = p.id,
    title = p.title,
    isStarred = false, // PR 5+: pull from the persisted item.
    // PR #76: surface the persisted incognito flag so the sidebar dot
    // lights up for the user.
    isIncognito = p.isIncognito,
    isToolCall = p.messages.isNotEmpty(),
    updatedAtMillis = p.lastMessageAtMillis,
)

/**
 * Composable helper: provide a `ChatHistoryStore` from the AppContainer
 * so screens can grab a `StateFlow<List<ChatHistoryItem>>` directly.
 */
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
