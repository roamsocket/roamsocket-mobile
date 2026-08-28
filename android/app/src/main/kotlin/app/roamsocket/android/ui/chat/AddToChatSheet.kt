package app.roamsocket.android.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.LocationOn
import androidx.compose.material.icons.outlined.ManageSearch
import androidx.compose.material.icons.outlined.Work
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.roamsocket.android.data.ToolAccessLevel
import app.roamsocket.core.projects.ProjectItem
import kotlinx.coroutines.launch

/**
 * Bottom sheet for the chat composer's `+` button. Mirrors the iOS
 * `AddToChatSheet`: four list rows (start coding session / add files /
 * add to project / tool access) followed by three toggles (research,
 * web search, location — Health is iOS-only) and a "Connectors" link at
 * the bottom.
 *
 * Each action takes a coroutine callback so the chat composable can
 * dismiss the sheet first, then run the actual side effect (navigate,
 * launch a SAF picker, set a toggle, etc.).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddToChatSheet(
    researchEnabled: Boolean,
    webSearchEnabled: Boolean,
    locationEnabled: Boolean,
    toolAccess: ToolAccessLevel,
    /** The user's projects (already collected by the host). */
    projects: List<ProjectItem>,
    /** The currently-active project, or null. */
    currentProject: ProjectItem?,
    onDismiss: () -> Unit,
    onStartCodingSession: () -> Unit,
    onAddFiles: () -> Unit,
    onPickProject: (ProjectItem) -> Unit,
    onCreateProjectAndAttach: (name: String) -> Unit,
    onShowConnectors: () -> Unit,
    onSetResearchEnabled: (Boolean) -> Unit,
    onSetWebSearchEnabled: (Boolean) -> Unit,
    onSetLocationEnabled: (Boolean) -> Unit,
    onSetToolAccess: (ToolAccessLevel) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var showToolAccessPicker by remember { mutableStateOf(false) }
    var showProjectPicker by remember { mutableStateOf(false) }
    var newProjectName by remember { mutableStateOf("") }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            // Header — title with leading X button.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 4.dp, bottom = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onDismiss) {
                    Icon(
                        imageVector = Icons.Outlined.Close,
                        contentDescription = "Close",
                        tint = MaterialTheme.colorScheme.onSurface,
                    )
                }
                Text(
                    text = "Add to Chat",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(start = 4.dp),
                )
            }

            // ----- List rows -----
            SheetRow(
                icon = Icons.Outlined.Code,
                title = "Start coding session",
                onClick = {
                    scope.launch { sheetState.hide() }
                    onStartCodingSession()
                    onDismiss()
                },
            )
            SheetRow(
                icon = Icons.Outlined.Description,
                title = "Add files",
                onClick = {
                    scope.launch { sheetState.hide() }
                    onAddFiles()
                    onDismiss()
                },
            )
            SheetRow(
                icon = Icons.Outlined.Folder,
                title = "Add to project",
                trailing = currentProject?.name ?: "None",
                showChevron = true,
                onClick = {
                    // Toggle the inline picker in place (no sheet hide) so
                    // the user can pick from the same sheet and stay in flow.
                    showProjectPicker = !showProjectPicker
                },
            )
            if (showProjectPicker) {
                ProjectPickerInline(
                    projects = projects,
                    onPick = { project ->
                        scope.launch { sheetState.hide() }
                        onPickProject(project)
                        onDismiss()
                    },
                    onCreate = { name ->
                        scope.launch { sheetState.hide() }
                        onCreateProjectAndAttach(name)
                        onDismiss()
                    },
                )
            }
            SheetRow(
                icon = Icons.Outlined.Work,
                title = "Tool access",
                trailing = toolAccess.display,
                showChevron = true,
                onClick = { showToolAccessPicker = true },
            )

            Spacer(Modifier.height(16.dp))

            // ----- Toggles -----
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column {
                    ToggleRow(
                        icon = Icons.Outlined.ManageSearch,
                        title = "Research",
                        subtitle = "Multi-query web search and Wikipedia for deeper answers.",
                        checked = researchEnabled,
                        onCheckedChange = onSetResearchEnabled,
                    )
                    ToggleRow(
                        icon = Icons.Outlined.Language,
                        title = "Web search",
                        subtitle = "Search the web for the latest message and share sources with the model.",
                        checked = webSearchEnabled,
                        onCheckedChange = onSetWebSearchEnabled,
                    )
                    ToggleRow(
                        icon = Icons.Outlined.LocationOn,
                        title = "Location",
                        subtitle = "Share where you are for local answers and context.",
                        checked = locationEnabled,
                        onCheckedChange = onSetLocationEnabled,
                    )
                }
            }

            Spacer(Modifier.height(12.dp))

            // ----- Connectors -----
            SheetRow(
                icon = Icons.Outlined.Apps,
                title = "Connectors",
                showChevron = true,
                onClick = {
                    scope.launch { sheetState.hide() }
                    onShowConnectors()
                    onDismiss()
                },
            )

            Spacer(Modifier.height(16.dp))
        }
    }

    if (showToolAccessPicker) {
        ToolAccessPickerSheet(
            current = toolAccess,
            onDismiss = { showToolAccessPicker = false },
            onSelect = { level ->
                onSetToolAccess(level)
                showToolAccessPicker = false
            },
        )
    }
}

@Composable
private fun SheetRow(
    icon: ImageVector,
    title: String,
    trailing: String? = null,
    showChevron: Boolean = false,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceContainerHighest),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.size(20.dp),
            )
        }
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        if (trailing != null) {
            Text(
                text = trailing,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (showChevron) {
            Icon(
                imageVector = Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun ToggleRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.size(22.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = MaterialTheme.colorScheme.onPrimary,
                checkedTrackColor = MaterialTheme.colorScheme.primary,
            ),
        )
    }
}

/**
 * Sub-sheet for choosing the desktop agent's tool access level
 * (Auto / Read-only / Full). iOS uses a single sheet; Android splits
 * it into a child modal because the parent sheet's buttons stay
 * tappable in the dimmed background.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ToolAccessPickerSheet(
    current: ToolAccessLevel,
    onDismiss: () -> Unit,
    onSelect: (ToolAccessLevel) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            Text(
                text = "Tool access",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(start = 8.dp, top = 4.dp, bottom = 8.dp),
            )
            ToolAccessLevel.values().forEach { level ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .clickable { onSelect(level) }
                        .padding(horizontal = 8.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = if (level == current) Icons.Outlined.Apps else Icons.Outlined.Add,
                        contentDescription = null,
                        tint = if (level == current) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(22.dp),
                    )
                    Spacer(Modifier.size(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = level.display,
                            style = MaterialTheme.typography.bodyLarge,
                            fontWeight = if (level == current) FontWeight.SemiBold else FontWeight.Normal,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = level.description,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
            TextButton(
                onClick = onDismiss,
                modifier = Modifier
                    .align(Alignment.End)
                    .padding(end = 8.dp, top = 4.dp, bottom = 12.dp),
            ) { Text("Cancel") }
        }
    }
}

/**
 * Inline picker that expands under the "Add to project" row. Mirrors
 * the iOS AddToChatSheet's project picker behavior: list of existing
 * projects (tap to attach) + a "New project…" inline create field
 * (Create / Cancel). Hides in place rather than nesting a new sheet
 * so the user can pick without losing composer state.
 */
@Composable
private fun ProjectPickerInline(
    projects: List<ProjectItem>,
    onPick: (ProjectItem) -> Unit,
    onCreate: (name: String) -> Unit,
) {
    var showCreate by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Surface(
            shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surfaceVariant,
            tonalElevation = 0.dp,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(modifier = Modifier.padding(vertical = 4.dp)) {
                if (projects.isEmpty()) {
                    Text(
                        "No projects yet — create one below.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                } else {
                    projects.forEach { project ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onPick(project) }
                                .padding(horizontal = 16.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.Folder,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(Modifier.size(10.dp))
                            Text(
                                project.name,
                                style = MaterialTheme.typography.bodyLarge,
                                color = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
                // Inline "New project…" entry
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            showCreate = !showCreate
                            if (showCreate) newName = ""
                        }
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Add,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.size(10.dp))
                    Text(
                        "New project…",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
                if (showCreate) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        OutlinedTextField(
                            value = newName,
                            onValueChange = { newName = it.take(80) },
                            placeholder = { Text("Project name") },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.size(8.dp))
                        TextButton(
                            onClick = {
                                val trimmed = newName.trim()
                                if (trimmed.isNotEmpty()) onCreate(trimmed)
                            },
                            enabled = newName.isNotBlank(),
                        ) { Text("Create") }
                        TextButton(onClick = { showCreate = false }) { Text("Cancel") }
                    }
                }
            }
        }
    }
}
