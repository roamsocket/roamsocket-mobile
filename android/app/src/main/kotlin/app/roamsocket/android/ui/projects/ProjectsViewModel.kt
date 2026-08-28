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
