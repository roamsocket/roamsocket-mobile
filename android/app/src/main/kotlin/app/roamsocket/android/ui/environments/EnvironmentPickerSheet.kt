package app.roamsocket.android.ui.environments

import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.protocol.EnvironmentConfig
import app.roamsocket.core.protocol.NetworkAccess
import kotlinx.coroutines.launch

/**
 * "Choose environment" bottom sheet. Lists every saved
 * [EnvironmentConfig] and offers a + button to create a new one.
 * Tapping a row selects it (and writes the selection to
 * [EnvironmentStore]); long-pressing a row prompts to delete it.
 *
 * Mirrors iOS `EnvironmentPickerSheet` in
 * `ios/App/Sources/Features/Environments/EnvironmentPickerSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EnvironmentPickerSheet(
    store: EnvironmentStore,
    onDismiss: () -> Unit,
) {
    val envs by store.environments.collectAsState()
    val selected = store.selected
    var pendingDelete by remember { mutableStateOf<EnvironmentConfig?>(null) }
    var showNew by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Palette.Background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            SheetHeader(
                onClose = onDismiss,
                onAdd = { showNew = true },
            )
            if (envs.isEmpty()) {
                EmptyEnvironmentsView()
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(0.dp),
                ) {
                    items(items = envs, key = { it.name }) { env ->
                        EnvironmentRow(
                            env = env,
                            isSelected = env.name == selected?.name,
                            onSelect = {
                                store.select(env.name)
                                scope.launch { sheetState.hide() }.invokeOnCompletion {
                                    onDismiss()
                                }
                            },
                            onDelete = { pendingDelete = env },
                        )
                        RowDivider()
                    }
                }
            }
            Spacer(modifier = Modifier.height(16.dp))
        }
    }

    if (showNew) {
        NewEnvironmentDialog(
            onDismiss = { showNew = false },
            onCreate = { newEnv ->
                store.addOrUpdate(newEnv)
                store.select(newEnv.name)
                showNew = false
            },
        )
    }

    val target = pendingDelete
    if (target != null) {
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete \"${target.name}\"?") },
            text = { Text("This removes the environment from the device. New sessions will fall back to the next saved environment.") },
            confirmButton = {
                TextButton(onClick = {
                    store.delete(target.name)
                    pendingDelete = null
                }) {
                    Text("Delete", color = Palette.Danger)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun SheetHeader(onClose: () -> Unit, onAdd: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onClose) {
            Icon(
                imageVector = Icons.Outlined.Close,
                contentDescription = "Close",
                tint = Palette.TextPrimary,
            )
        }
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = "Choose environment",
            color = Palette.TextPrimary,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(modifier = Modifier.weight(1f))
        IconButton(
            onClick = onAdd,
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(Palette.SurfaceElevated),
        ) {
            Icon(
                imageVector = Icons.Outlined.Add,
                contentDescription = "New environment",
                tint = Palette.TextPrimary,
            )
        }
    }
}

@Composable
private fun EnvironmentRow(
    env: EnvironmentConfig,
    isSelected: Boolean,
    onSelect: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable { onSelect() }
            .padding(horizontal = 12.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(Palette.SurfaceElevated),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Outlined.Wifi,
                contentDescription = null,
                tint = Palette.Accent,
                modifier = Modifier.size(16.dp),
            )
        }
        Spacer(modifier = Modifier.size(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = env.name,
                color = Palette.TextPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = env.networkAccess.displayName,
                color = Palette.TextSecondary,
                fontSize = 12.sp,
                maxLines = 1,
            )
        }
        if (isSelected) {
            Icon(
                imageVector = Icons.Outlined.Check,
                contentDescription = "Selected",
                tint = Palette.Accent,
                modifier = Modifier.size(18.dp),
            )
        } else {
            IconButton(
                onClick = onDelete,
                modifier = Modifier.size(32.dp),
            ) {
                Icon(
                    imageVector = Icons.Outlined.Delete,
                    contentDescription = "Delete",
                    tint = Palette.TextTertiary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@Composable
private fun RowDivider() {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = Palette.Background,
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(Palette.Divider),
        )
    }
}

@Composable
private fun EmptyEnvironmentsView() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(32.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "No environments yet. Tap + to create one.",
            color = Palette.TextSecondary,
            fontSize = 14.sp,
        )
    }
}
