package app.roamsocket.android.ui.projects

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import app.roamsocket.android.ui.LocalOpenSidebar
import app.roamsocket.core.projects.ProjectChatItem

/**
 * Project detail: chats list + Instructions / Memory sheets.
 * Mirrors iOS `Sidebar/ProjectDetailView.swift`. Renders the
 * instruction pill + memory banner on top, then the project's
 * chat list (newest first). Tapping a chat row opens it in the
 * chat view; the host is responsible for navigation via
 * [onOpenChat] after the coordinator pins the active chat.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectDetailScreen(
    projectId: String,
    onBack: () -> Unit,
    /**
     * Called when the user wants to open a project chat. The host
     * (RootView) navigates to [SidebarDestination.Chats]; the
     * active project + chat are already set on the coordinator.
     */
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
                                // repository so ChatViewModel can resolve it; the
                                // ChatScreen will hydrate from the project's chat
                                // store via the active project branch.
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
                    modifier = Modifier
                        .padding(start = 4.dp)
                        .size(14.dp),
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
                Icon(
                    Icons.Outlined.Edit,
                    contentDescription = "Rename",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            IconButton(onClick = onDelete) {
                Icon(
                    Icons.Outlined.Delete,
                    contentDescription = "Delete",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
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
