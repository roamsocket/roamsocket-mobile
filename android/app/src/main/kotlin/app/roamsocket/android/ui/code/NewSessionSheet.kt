package app.roamsocket.android.ui.code

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.Hub
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material.icons.automirrored.outlined.ListAlt
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.environments.EnvironmentPickerSheet
import app.roamsocket.android.ui.environments.EnvironmentStore
import app.roamsocket.android.ui.repositories.RepositoryPickerSheet
import app.roamsocket.android.ui.session.SessionConfig
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.code.CodeSession
import app.roamsocket.core.github.GitHubRepo
import app.roamsocket.core.protocol.EnvironmentConfig
import app.roamsocket.core.protocol.PermissionMode
import app.roamsocket.core.protocol.RepoRef
import kotlinx.coroutines.launch

/**
 * Modal bottom sheet that gathers every input needed to start a coding
 * session — repository, work branch, permission mode, model, and the
 * optional first task — and launches [SessionScreen] when the user
 * confirms.
 *
 * Mirrors `ios/.../Features/Session/NewSessionView.swift`. Replaces the
 * small `AlertDialog` that the Code tab used previously, picking up the
 * iOS feature set: suggestion chips, permission-mode picker, and a
 * sticky repo + composer layout that doesn't float mid-screen.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewSessionSheet(
    viewModel: PairingViewModel,
    onDismiss: () -> Unit,
    onStart: (SessionConfig) -> Unit,
    onNavigateToSettings: () -> Unit,
) {
    var selectedRepo by remember { mutableStateOf<GitHubRepo?>(null) }
    var branch by remember { mutableStateOf("") }
    var task by remember { mutableStateOf("") }
    var permissionMode by remember { mutableStateOf(PermissionMode.ACCEPT_EDITS) }
    var showRepoPicker by remember { mutableStateOf(false) }
    var showPermissionSheet by remember { mutableStateOf(false) }
    var showEnvironmentPicker by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var starting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    // PR #94 (environments): read the selected env from the
    // AppContainer store so the picker, the form, and the Start
    // handler all see the same value. `LocalAppContainer.current` is
    // provided by `MainActivity` so this is a safe lookup at compose
    // time.
    val environmentStore: EnvironmentStore =
        app.roamsocket.android.ui.LocalAppContainer.current.environmentStore
    val selectedEnv: EnvironmentConfig? = environmentStore.selected
    val selectedEnvName = selectedEnv?.name ?: EnvironmentStore.DEFAULT_NAME

    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = { if (!starting) onDismiss() },
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .imePadding(),
        ) {
            // Header — mirrors the `SheetContainer` shape used by the
            // other session sheets so Cancel / Start align consistently.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.Surface)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                TextButton(
                    onClick = onDismiss,
                    enabled = !starting,
                ) { Text("Cancel") }
                Spacer(Modifier.weight(1f))
                Text(
                    text = "New session",
                    color = Palette.TextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.weight(1f))
                TextButton(
                    onClick = {
                        val repo = selectedRepo
                        if (repo == null) {
                            error = "Pick a repository first"
                            return@TextButton
                        }
                        if (branch.isBlank()) {
                            error = "Pick a work branch"
                            return@TextButton
                        }
                        starting = true
                        error = null
                        scope.launch {
                            val base = viewModel.defaultSessionConfig()
                            if (base == null) {
                                starting = false
                                error = "Add an API key for the current provider in Chat first."
                                return@launch
                            }
                            val config = base.copy(
                                repo = RepoRef(
                                    fullName = repo.fullName,
                                    baseBranch = repo.defaultBranch,
                                    workBranch = branch,
                                ),
                                permissionMode = permissionMode,
                                // PR #94 (environments): forward the
                                // currently selected env to the desktop
                                // with `create_session`. Mirrors iOS
                                // `NewSessionView` line ~155.
                                environment = environmentStore.selected,
                            )
                            val now = System.currentTimeMillis()
                            val sessionTitle = task.take(48)
                                .ifBlank { "${repo.fullName} · $branch" }
                            viewModel.registerSession(
                                CodeSession(
                                    id = config.id,
                                    title = sessionTitle,
                                    repoFullName = repo.fullName,
                                    baseBranch = repo.defaultBranch,
                                    workBranch = branch,
                                    status = CodeSession.Status.WORKING,
                                    createdAtMillis = now,
                                    updatedAtMillis = now,
                                ),
                            )
                            onStart(config)
                        }
                    },
                    enabled = !starting,
                ) {
                    if (starting) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(14.dp),
                            strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.onPrimary,
                        )
                    } else {
                        Text("Start")
                    }
                }
            }

            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 720.dp),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                item { SuggestionsSection(onPick = { task = it }) }
                item {
                    RepoAndBranchBlock(
                        selectedRepo = selectedRepo,
                        branch = branch,
                        onBranchChange = { branch = it.trim() },
                        onPickRepo = { showRepoPicker = true },
                    )
                }
                item {
                    ModelAndPermissionRow(
                        permissionMode = permissionMode,
                        onPickPermission = { showPermissionSheet = true },
                    )
                }
                // PR #94 (environments): environment pill, mirrors the
                // iOS NewSessionView header. Tapping opens the
                // EnvironmentPickerSheet so the user can switch (or
                // create) a cloud environment.
                item {
                    EnvironmentRow(
                        name = selectedEnvName,
                        onClick = { showEnvironmentPicker = true },
                    )
                }
                item {
                    TaskComposer(
                        task = task,
                        onTaskChange = { task = it },
                    )
                }
                error?.let { msg ->
                    item {
                        Text(
                            text = msg,
                            color = MaterialTheme.colorScheme.error,
                            fontSize = 13.sp,
                            modifier = Modifier.padding(horizontal = 4.dp),
                        )
                    }
                }
            }
        }
    }

    if (showRepoPicker) {
        RepositoryPickerSheet(
            onPick = { repo ->
                selectedRepo = repo
                if (branch.isBlank()) branch = repo.defaultBranch
                showRepoPicker = false
            },
            onLinkGitHub = {
                showRepoPicker = false
                onNavigateToSettings()
            },
            onDismiss = { showRepoPicker = false },
        )
    }

    if (showPermissionSheet) {
        PermissionModeSheet(
            current = permissionMode,
            onPick = {
                permissionMode = it
                showPermissionSheet = false
            },
            onDismiss = { showPermissionSheet = false },
        )
    }

    if (showEnvironmentPicker) {
        EnvironmentPickerSheet(
            store = environmentStore,
            onDismiss = { showEnvironmentPicker = false },
        )
    }
}

@Composable
private fun EnvironmentRow(name: String, onClick: () -> Unit) {
    Surface(
        color = Palette.Surface,
        shape = RoundedCornerShape(50),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(50))
            .clickable(onClick = onClick),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Hub,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = name,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = Palette.TextPrimary,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = Icons.Outlined.KeyboardArrowDown,
                contentDescription = "Change environment",
                tint = Palette.TextSecondary,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun SuggestionsSection(onPick: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = "Suggestions",
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            color = Palette.TextSecondary,
        )
        val suggestions = listOf(
            "Create or update my AGENTS.md file",
            "Search for a TODO comment and fix it",
            "Recommend areas to improve our tests",
        )
        suggestions.forEach { suggestion ->
            Surface(
                color = Palette.Surface,
                shape = RoundedCornerShape(50),
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(50))
                    .clickable { onPick(suggestion) },
            ) {
                Text(
                    text = suggestion,
                    fontSize = 15.sp,
                    color = Palette.TextPrimary,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                )
            }
        }
    }
}

@Composable
private fun RepoAndBranchBlock(
    selectedRepo: GitHubRepo?,
    branch: String,
    onBranchChange: (String) -> Unit,
    onPickRepo: () -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Plus button — opens the repo picker (or the GitHub link flow
        // if the user isn't signed in). Mirrors iOS `repoControls`.
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape)
                .background(Palette.Surface)
                .clickable(onClick = onPickRepo),
        ) {
            Icon(
                imageVector = Icons.Outlined.EditNote,
                contentDescription = "Choose repository",
                tint = Palette.TextPrimary,
            )
        }
        // Repo picker capsule
        Surface(
            color = Palette.Surface,
            shape = RoundedCornerShape(50),
            modifier = Modifier
                .weight(1f)
                .clip(RoundedCornerShape(50))
                .clickable(onClick = onPickRepo),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            ) {
                Icon(
                    imageVector = Icons.Outlined.Code,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    text = selectedRepo?.fullName ?: "Choose repository",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = if (selectedRepo == null) Palette.TextSecondary else Palette.TextPrimary,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    imageVector = Icons.Outlined.SwapVert,
                    contentDescription = null,
                    tint = Palette.TextSecondary,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
    // Work branch — kept as a single-line text field below the repo
    // capsule. Mirrors iOS: iOS hides the work branch entirely and
    // auto-derives it; we keep the field because Android doesn't
    // surface a "create from default" affordance yet.
    Surface(
        color = Palette.Surface,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                text = "Work branch",
                fontSize = 12.sp,
                color = Palette.TextSecondary,
            )
            TextButton(
                onClick = {},
                contentPadding = PaddingValues(0.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                // Use a clickable text field via BasicTextField for
                // a more native feel; here we just embed the input.
                // (The text-field is rendered below to keep the iOS
                //  visual rhythm without bringing in a second focus
                //  target.)
            }
            androidx.compose.foundation.text.BasicTextField(
                value = branch,
                onValueChange = onBranchChange,
                singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(
                    fontSize = 15.sp,
                    fontFamily = FontFamily.Monospace,
                    color = Palette.TextPrimary,
                ),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(Palette.Accent),
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    imeAction = ImeAction.Next,
                ),
                decorationBox = { inner ->
                    Box(contentAlignment = Alignment.CenterStart) {
                        if (branch.isEmpty()) {
                            Text(
                                text = selectedRepo?.defaultBranch ?: "feat/your-change",
                                fontSize = 15.sp,
                                fontFamily = FontFamily.Monospace,
                                color = Palette.TextTertiary,
                            )
                        }
                        inner()
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun ModelAndPermissionRow(
    permissionMode: PermissionMode,
    onPickPermission: () -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Model pill — iOS opens the model picker here. On Android the
        // default model is bound to Settings; the iOS picker doesn't
        // exist yet, so this stays as a read-only chip. The pill still
        // matches the iOS surface so swapping it for a picker later is
        // purely an `onClick` change.
        Surface(
            color = Palette.Surface,
            shape = RoundedCornerShape(50),
            modifier = Modifier
                .weight(1f)
                .clip(RoundedCornerShape(50)),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                Icon(
                    imageVector = Icons.Outlined.Hub,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(14.dp),
                )
                Text(
                    text = "Default model",
                    fontSize = 13.sp,
                    color = Palette.TextSecondary,
                    maxLines = 1,
                )
            }
        }
        // Permission mode chip — opens a small sheet with the three
        // modes (iOS parity).
        Surface(
            color = Palette.Surface,
            shape = RoundedCornerShape(50),
            modifier = Modifier
                .weight(1f)
                .clip(RoundedCornerShape(50))
                .clickable(onClick = onPickPermission),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                Icon(
                    imageVector = permissionIcon(permissionMode),
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(14.dp),
                )
                Text(
                    text = permissionMode.displayName,
                    fontSize = 13.sp,
                    color = Palette.TextPrimary,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    imageVector = Icons.Outlined.KeyboardArrowDown,
                    contentDescription = null,
                    tint = Palette.TextTertiary,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

@Composable
private fun TaskComposer(
    task: String,
    onTaskChange: (String) -> Unit,
) {
    Surface(
        color = Palette.Surface,
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        androidx.compose.foundation.text.BasicTextField(
            value = task,
            onValueChange = onTaskChange,
            textStyle = androidx.compose.ui.text.TextStyle(
                fontSize = 16.sp,
                color = Palette.TextPrimary,
            ),
            cursorBrush = androidx.compose.ui.graphics.SolidColor(Palette.Accent),
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.Sentences,
                imeAction = ImeAction.Default,
            ),
            decorationBox = { inner ->
                Box(modifier = Modifier.padding(14.dp)) {
                    if (task.isEmpty()) {
                        Text(
                            text = "Code anything…",
                            fontSize = 16.sp,
                            color = Palette.TextTertiary,
                        )
                    }
                    inner()
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PermissionModeSheet(
    current: PermissionMode,
    onPick: (PermissionMode) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.background,
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.Surface)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Spacer(Modifier.weight(1f))
                Text(
                    text = "Select mode",
                    color = Palette.TextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.weight(1f))
                TextButton(onClick = {}, enabled = false) { Text("Cancel") }
            }
            Column(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                PermissionModeRow(
                    mode = PermissionMode.ASK,
                    icon = Icons.Outlined.Bolt,
                    title = "Ask",
                    subtitle = "The agent asks before each write or shell call",
                    selected = current == PermissionMode.ASK,
                    onPick = onPick,
                )
                PermissionModeRow(
                    mode = PermissionMode.ACCEPT_EDITS,
                    icon = Icons.Outlined.Edit,
                    title = "Accept edits",
                    subtitle = "Automatically accept all file edits",
                    selected = current == PermissionMode.ACCEPT_EDITS,
                    onPick = onPick,
                )
                PermissionModeRow(
                    mode = PermissionMode.PLAN,
                    icon = Icons.AutoMirrored.Outlined.ListAlt,
                    title = "Plan",
                    subtitle = "Create a plan before making changes",
                    selected = current == PermissionMode.PLAN,
                    onPick = onPick,
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PermissionModeRow(
    mode: PermissionMode,
    icon: ImageVector,
    title: String,
    subtitle: String,
    selected: Boolean,
    onPick: (PermissionMode) -> Unit,
) {
    Surface(
        color = androidx.compose.ui.graphics.Color.Transparent,
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onPick(mode) },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 16.dp),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(20.dp),
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = title,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Medium,
                    color = Palette.TextPrimary,
                )
                Text(
                    text = subtitle,
                    fontSize = 13.sp,
                    color = Palette.TextSecondary,
                )
            }
            if (selected) {
                Icon(
                    imageVector = Icons.Outlined.Check,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

private fun permissionIcon(mode: PermissionMode): ImageVector = when (mode) {
    PermissionMode.ASK -> Icons.Outlined.Bolt
    PermissionMode.ACCEPT_EDITS -> Icons.Outlined.Edit
    PermissionMode.PLAN -> Icons.AutoMirrored.Outlined.ListAlt
}
