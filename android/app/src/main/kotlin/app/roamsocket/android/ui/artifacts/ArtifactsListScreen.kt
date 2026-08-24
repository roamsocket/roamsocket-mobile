package app.roamsocket.android.ui.artifacts

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Saved chat artifacts — long assistant replies and code blocks the user
 * has accumulated. Tapping a row opens the detail view; the trailing
 * trash icon deletes it; the overflow menu offers a "Clear all" action.
 *
 * Ports [ArtifactsListView] from
 * `ios/App/Sources/Features/Artifacts/ArtifactsListView.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArtifactsListScreen(
    store: ArtifactStore,
    onBack: () -> Unit,
    onOpenArtifact: (String) -> Unit,
) {
    val artifacts by store.artifacts.collectAsState()
    var menuOpen by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Palette.Background)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            TopAppBar(
                title = {
                    Text(
                        text = "Artifacts",
                        color = Palette.TextPrimary,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Outlined.ArrowBack,
                            contentDescription = "Back",
                            tint = Palette.TextPrimary,
                        )
                    }
                },
                actions = {
                    if (artifacts.isNotEmpty()) {
                        Box {
                            IconButton(onClick = { menuOpen = true }) {
                                Icon(
                                    imageVector = Icons.Outlined.MoreVert,
                                    contentDescription = "More",
                                    tint = Palette.TextPrimary,
                                )
                            }
                            DropdownMenu(
                                expanded = menuOpen,
                                onDismissRequest = { menuOpen = false },
                            ) {
                                DropdownMenuItem(
                                    text = { Text("Clear all") },
                                    onClick = {
                                        menuOpen = false
                                        confirmClear = true
                                    },
                                    leadingIcon = {
                                        Icon(
                                            imageVector = Icons.Outlined.Delete,
                                            contentDescription = null,
                                        )
                                    },
                                )
                            }
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Palette.Background,
                ),
            )

            if (artifacts.isEmpty()) {
                EmptyArtifactsView()
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        start = 16.dp,
                        end = 16.dp,
                        top = 8.dp,
                        bottom = 16.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    items(
                        items = artifacts,
                        key = { it.id },
                    ) { artifact ->
                        ArtifactRow(
                            artifact = artifact,
                            onClick = { onOpenArtifact(artifact.id) },
                            onDelete = { store.delete(artifact.id) },
                        )
                    }
                }
            }
        }

        if (confirmClear) {
            AlertDialog(
                onDismissRequest = { confirmClear = false },
                title = { Text("Clear all artifacts?") },
                text = {
                    Text("This permanently removes every saved artifact. The chats they came from are not affected.")
                },
                confirmButton = {
                    TextButton(onClick = {
                        store.clearAll()
                        confirmClear = false
                    }) {
                        Text("Clear all", color = Palette.Danger)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { confirmClear = false }) {
                        Text("Cancel")
                    }
                },
            )
        }
    }
}

/**
 * Single-line artifact card — title + meta + chevron, matching the
 * iOS `artifactCard` layout (compact, not a multi-line preview).
 */
@Composable
private fun ArtifactRow(
    artifact: Artifact,
    onClick: () -> Unit,
    onDelete: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable { onClick() },
        color = Palette.Surface,
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, Palette.Divider),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = artifact.title,
                    color = Palette.TextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                ArtifactMeta(artifact)
            }
            Spacer(modifier = Modifier.width(8.dp))
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
            Icon(
                imageVector = Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = Palette.TextTertiary,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun ArtifactMeta(artifact: Artifact) {
    val hasChat = artifact.chatId != null
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "${artifact.lineCount} lines",
            color = Palette.TextTertiary,
            fontSize = 12.sp,
            fontFamily = FontFamily.Monospace,
            maxLines = 1,
        )
        MetaDot()
        Text(
            text = formatDate(artifact.createdAt),
            color = Palette.TextTertiary,
            fontSize = 12.sp,
            maxLines = 1,
        )
        if (hasChat) {
            MetaDot()
            Text(
                text = "In chat",
                color = Palette.Accent,
                fontSize = 12.sp,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun MetaDot() {
    Text(
        text = "·",
        color = Palette.TextTertiary,
        fontSize = 12.sp,
    )
}

@Composable
private fun EmptyArtifactsView() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Layers,
                contentDescription = null,
                tint = Palette.TextSecondary,
                modifier = Modifier.size(36.dp),
            )
            Text(
                text = "No artifacts yet",
                color = Palette.TextPrimary,
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Long assistant replies and code blocks you receive in chat will appear here automatically. Tap one to open it beside the original message.",
                color = Palette.TextSecondary,
                fontSize = 14.sp,
                textAlign = TextAlign.Center,
            )
        }
    }
}

private fun formatDate(epochMillis: Long): String {
    val format = SimpleDateFormat("MMM d, yyyy", Locale.getDefault())
    return format.format(Date(epochMillis))
}
