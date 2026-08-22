package app.roamsocket.android.ui.session

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.protocol.FileChange
import app.roamsocket.core.protocol.FileEntry
import app.roamsocket.core.protocol.ServerMessage
import app.roamsocket.core.server.Endpoint
import app.roamsocket.core.server.WorkspaceRpc
import kotlinx.coroutines.launch

/**
 * Workspace file browser + Diffs tab. Mirrors the iOS `FileExplorerView`
 * (`ios/.../SessionToolsView.swift`).
 */
@Composable
fun FileExplorerPane(
    sessionId: String,
    endpoint: Endpoint?,
    token: String?,
    onOpenFile: (path: String, preferDiff: Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val state = remember { FileExplorerState() }
    val canStart = endpoint != null && !token.isNullOrEmpty()
    var mode by remember { mutableStateOf(FileMode.Browse) }

    LaunchedEffect(sessionId, endpoint?.baseURL, token) {
        if (canStart) {
            state.load(scope, endpoint!!, token!!, sessionId, "")
        } else {
            state.errorMessage = "Pair a desktop server first."
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
    ) {
        ModePicker(mode = mode, onChange = { mode = it })

        if (mode == FileMode.Browse) {
            Breadcrumb(
                currentPath = state.currentPath,
                onJump = { newPath ->
                    state.currentPath = newPath
                    if (canStart) scope.launch {
                        state.load(scope, endpoint!!, token!!, sessionId, newPath)
                    }
                },
            )
        }

        state.errorMessage?.let { err ->
            Text(
                text = err,
                color = MaterialTheme.colorScheme.error,
                fontSize = 13.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }

        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            when (mode) {
                FileMode.Browse -> FileList(
                    state = state,
                    onPick = { entry ->
                        if (entry.isDirectory) {
                            state.currentPath = entry.path
                            if (canStart) scope.launch {
                                state.load(scope, endpoint!!, token!!, sessionId, entry.path)
                            }
                        } else {
                            onOpenFile(entry.path, entry.changeStatus != null)
                        }
                    },
                )
                FileMode.Diffs -> DiffList(state = state, onOpenFile = onOpenFile)
            }
            if (state.loading) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(MaterialTheme.colorScheme.background.copy(alpha = 0.4f)),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                        color = Palette.Accent,
                    )
                }
            }
        }
    }
}

private enum class FileMode { Browse, Diffs }

@Composable
private fun ModePicker(mode: FileMode, onChange: (FileMode) -> Unit) {
    val options = listOf(FileMode.Browse to "Browse", FileMode.Diffs to "Diffs")
    SingleChoiceSegmentedButtonRow(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        options.forEachIndexed { index, (value, label) ->
            SegmentedButton(
                selected = mode == value,
                onClick = { onChange(value) },
                shape = SegmentedButtonDefaults.itemShape(index = index, count = options.size),
            ) { Text(label) }
        }
    }
}

@Composable
private fun Breadcrumb(currentPath: String, onJump: (String) -> Unit) {
    val crumbs = remember(currentPath) {
        buildList {
            add("repo" to "")
            if (currentPath.isNotEmpty()) {
                var accum = ""
                for (part in currentPath.split('/')) {
                    accum = if (accum.isEmpty()) part else "$accum/$part"
                    add(part to accum)
                }
            }
        }
    }
    val scroll = rememberScrollState()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(scroll)
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        crumbs.forEachIndexed { i, (title, path) ->
            if (i > 0) {
                Icon(
                    imageVector = Icons.Outlined.ChevronRight,
                    contentDescription = null,
                    tint = Palette.TextTertiary,
                    modifier = Modifier.size(10.dp),
                )
            }
            val isCurrent = path == currentPath
            Text(
                text = title,
                color = if (isCurrent) Palette.Accent else Palette.TextSecondary,
                fontSize = 13.sp,
                fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(if (isCurrent) Palette.SurfaceElevated else Palette.Background)
                    .clickable { onJump(path) }
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }
    }
}

@Composable
private fun FileList(
    state: FileExplorerState,
    onPick: (FileEntry) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(vertical = 4.dp),
    ) {
        if (state.currentPath.isNotEmpty()) {
            item("..") {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            state.currentPath = parentPath(state.currentPath)
                        }
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Outlined.ArrowBack,
                        contentDescription = null,
                        tint = Palette.TextSecondary,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = "..",
                        color = Palette.TextSecondary,
                        fontSize = 14.sp,
                    )
                }
            }
        }
        items(state.entries, key = { it.path }) { entry ->
            FileRow(entry = entry, onClick = { onPick(entry) })
        }
    }
}

@Composable
private fun FileRow(entry: FileEntry, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Icon(
            imageVector = if (entry.isDirectory) Icons.Outlined.Folder else Icons.Outlined.Description,
            contentDescription = null,
            tint = if (entry.isDirectory) Palette.Accent else Palette.TextSecondary,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(8.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = entry.name,
                color = Palette.TextPrimary,
                fontSize = 14.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
            )
            if (!entry.isDirectory) {
                Text(
                    text = formatSize(entry.size),
                    color = Palette.TextTertiary,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
        entry.changeStatus?.let { status ->
            Text(
                text = status,
                color = statusColor(status),
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(statusColor(status).copy(alpha = 0.15f))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
        if (entry.isDirectory) {
            Icon(
                imageVector = Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = Palette.TextTertiary,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

@Composable
private fun DiffList(
    state: FileExplorerState,
    onOpenFile: (String, Boolean) -> Unit,
) {
    if (state.changes.isEmpty() && state.fullDiff.isBlank()) {
        Text(
            text = if (state.loading) "Loading…" else "Working tree is clean.",
            color = Palette.TextSecondary,
            fontSize = 14.sp,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 16.dp),
        )
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(vertical = 4.dp),
    ) {
        if (state.changes.isNotEmpty()) {
            item("header") {
                Text(
                    text = "Changed files",
                    color = Palette.TextPrimary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
            items(state.changes, key = { it.path }) { change ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onOpenFile(change.path, true) }
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Text(
                        text = change.status,
                        color = statusColor(change.status),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.width(24.dp),
                    )
                    Text(
                        text = change.path,
                        color = Palette.TextPrimary,
                        fontSize = 13.sp,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.weight(1f),
                    )
                    Icon(
                        imageVector = Icons.Outlined.ChevronRight,
                        contentDescription = null,
                        tint = Palette.TextTertiary,
                        modifier = Modifier.size(12.dp),
                    )
                }
            }
        }
        if (state.fullDiff.isNotBlank()) {
            item("diff-header") {
                Text(
                    text = "Unified diff",
                    color = Palette.TextPrimary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
            item("diff-body") {
                ColumnizedDiff(patch = state.fullDiff)
            }
        }
    }
}

@Composable
internal fun ColumnizedDiff(patch: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp),
    ) {
        for (line in patch.split('\n')) {
            Text(
                text = if (line.isEmpty()) " " else line,
                color = diffColor(line),
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(diffBackground(line)),
            )
        }
    }
}

private fun diffColor(line: String): androidx.compose.ui.graphics.Color = when {
    line.startsWith("+++") || line.startsWith("---") -> Palette.TextSecondary
    line.startsWith("@@") -> Palette.Accent
    line.startsWith("+") -> Palette.Success
    line.startsWith("-") -> Palette.Danger
    else -> Palette.TextPrimary
}

private fun diffBackground(line: String): androidx.compose.ui.graphics.Color = when {
    line.startsWith("+") && !line.startsWith("+++") -> Palette.Success.copy(alpha = 0.12f)
    line.startsWith("-") && !line.startsWith("---") -> Palette.Danger.copy(alpha = 0.12f)
    line.startsWith("@@") -> Palette.Accent.copy(alpha = 0.12f)
    else -> Palette.Background
}

private fun statusColor(status: String): androidx.compose.ui.graphics.Color = when (status) {
    "A", "?" -> Palette.Success
    "D" -> Palette.Danger
    "M", "R", "C" -> Palette.Warning
    else -> Palette.Accent
}

private fun formatSize(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> "%.1f KB".format(bytes / 1024.0)
    else -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
}

private fun parentPath(path: String): String {
    val idx = path.lastIndexOf('/')
    return if (idx < 0) "" else path.substring(0, idx)
}

internal class FileExplorerState {
    var entries: List<FileEntry> by mutableStateOf(emptyList())
    var changes: List<FileChange> by mutableStateOf(emptyList())
    var fullDiff: String by mutableStateOf("")
    var currentPath: String by mutableStateOf("")
    var loading: Boolean by mutableStateOf(false)
    var errorMessage: String? by mutableStateOf(null)

    suspend fun load(
        scope: kotlinx.coroutines.CoroutineScope,
        endpoint: Endpoint,
        token: String,
        sessionId: String,
        path: String,
    ) {
        loading = true
        errorMessage = null
        try {
            val result = WorkspaceRpc.withConnection(
                endpoint = endpoint,
                token = token,
                send = { session -> session.send(app.roamsocket.core.protocol.ClientMessage.FileList(sessionId, path)) },
                match = { msg ->
                    when (msg) {
                        is ServerMessage.FileListResult ->
                            if (msg.path == path || (path.isEmpty() && (msg.path.isEmpty() || msg.path == "."))) {
                                Triple<List<FileEntry>, String?, List<FileChange>>(
                                    msg.entries,
                                    msg.diff,
                                    msg.changes ?: emptyList<FileChange>(),
                                )
                            } else null
                        is ServerMessage.Error -> {
                            errorMessage = msg.message
                            null
                        }
                        else -> null
                    }
                },
            )
            entries = result.first
            result.second?.let { fullDiff = it }
            changes = result.third
        } catch (e: Throwable) {
            errorMessage = e.message ?: e.javaClass.simpleName
        } finally {
            loading = false
        }
    }
}
