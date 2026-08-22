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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Save
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.protocol.ClientMessage
import app.roamsocket.core.protocol.ServerMessage
import app.roamsocket.core.server.Endpoint
import app.roamsocket.core.server.WorkspaceRpc
import kotlinx.coroutines.launch

/**
 * File viewer + editor. Loads content via `file_read`, supports save
 * via `file_write`, and shows a unified diff on the Diff tab when the
 * server returns one. Mirrors the iOS `FileViewerSheet`
 * (`ios/.../SessionToolsView.swift`).
 */
@Composable
fun FileViewerPane(
    sessionId: String,
    path: String,
    endpoint: Endpoint?,
    token: String?,
    preferDiff: Boolean = false,
    onClose: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val state = remember { FileViewerState() }
    var tab by remember { mutableStateOf(if (preferDiff) FileViewerTab.Diff else FileViewerTab.Edit) }
    val canStart = endpoint != null && !token.isNullOrEmpty()

    LaunchedEffect(sessionId, path, endpoint?.baseURL, token) {
        if (canStart) state.load(scope, endpoint!!, token!!, sessionId, path, preferDiff) { tab = it }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .background(Palette.Surface)
                .padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            TextButton(onClick = onClose) { Text("Done") }
            Spacer(Modifier.size(8.dp))
            Text(
                text = path.substringAfterLast('/'),
                color = Palette.TextPrimary,
                fontSize = 16.sp,
                fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                maxLines = 1,
            )
            if (state.saving) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            } else {
                TextButton(
                    onClick = {
                        if (canStart) scope.launch { state.save(endpoint!!, token!!, sessionId, path) }
                    },
                    enabled = state.canSave,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Save,
                        contentDescription = "Save",
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.size(4.dp))
                    Text("Save")
                }
            }
        }

        if (state.hasDiff || preferDiff) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                val options = listOf(
                    FileViewerTab.Edit to "Edit",
                    FileViewerTab.Diff to "Diff",
                )
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    options.forEachIndexed { index, (value, label) ->
                        SegmentedButton(
                            selected = tab == value,
                            onClick = { tab = value },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = options.size),
                        ) { Text(label) }
                    }
                }
            }
        }

        state.errorMessage?.let { err ->
            Text(
                text = err,
                color = MaterialTheme.colorScheme.error,
                fontSize = 13.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        state.statusMessage?.let { msg ->
            Text(
                text = msg,
                color = Palette.Accent,
                fontSize = 12.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }

        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            when (tab) {
                FileViewerTab.Edit -> FileEditor(
                    content = state.content,
                    enabled = !state.truncated,
                    onChange = { state.content = it },
                )
                FileViewerTab.Diff -> if (state.diff.isNotBlank()) {
                    ColumnizedDiff(patch = state.diff)
                } else {
                    Text(
                        text = "No diff available.",
                        color = Palette.TextTertiary,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
            if (state.loading) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(MaterialTheme.colorScheme.background.copy(alpha = 0.4f)),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                }
            }
        }

        if (state.truncated) {
            Text(
                text = "Truncated at 256 KB — editing disabled. Open on the desktop for the full file.",
                color = Palette.TextSecondary,
                fontSize = 12.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.SurfaceElevated)
                    .padding(8.dp),
            )
        }
    }
}

internal enum class FileViewerTab { Edit, Diff }

@Composable
private fun FileEditor(content: String, enabled: Boolean, onChange: (String) -> Unit) {
    val scroll = rememberScrollState()
    BasicTextField(
        value = content,
        onValueChange = { if (enabled) onChange(it) },
        textStyle = TextStyle(
            color = Palette.TextPrimary,
            fontSize = 13.sp,
            fontFamily = FontFamily.Monospace,
        ),
        cursorBrush = SolidColor(Palette.Accent),
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(scroll)
            .padding(12.dp),
    )
}

internal class FileViewerState {
    var content: String by mutableStateOf("")
    var originalContent: String by mutableStateOf("")
    var diff: String by mutableStateOf("")
    var loading: Boolean by mutableStateOf(true)
    var saving: Boolean by mutableStateOf(false)
    var truncated: Boolean by mutableStateOf(false)
    var errorMessage: String? by mutableStateOf(null)
    var statusMessage: String? by mutableStateOf(null)

    val hasDiff: Boolean get() = diff.isNotBlank()
    val isDirty: Boolean get() = content != originalContent
    val canSave: Boolean get() = isDirty && !saving && !truncated && !loading

    suspend fun load(
        scope: kotlinx.coroutines.CoroutineScope,
        endpoint: Endpoint,
        token: String,
        sessionId: String,
        path: String,
        preferDiff: Boolean,
        setTab: (FileViewerTab) -> Unit,
    ) {
        loading = true
        errorMessage = null
        try {
            val result = WorkspaceRpc.withConnection(
                endpoint = endpoint,
                token = token,
                send = { session -> session.send(ClientMessage.FileRead(sessionId, path)) },
                match = { msg ->
                    when (msg) {
                        is ServerMessage.FileReadResult -> if (msg.path == path) {
                            Triple<String, Boolean, String?>(msg.content, msg.truncated, msg.diff)
                        } else null
                        is ServerMessage.Error -> { errorMessage = msg.message; null }
                        else -> null
                    }
                },
            )
            content = result.first
            originalContent = result.first
            truncated = result.second
            diff = result.third.orEmpty()
            if (preferDiff && hasDiff) setTab(FileViewerTab.Diff) else setTab(FileViewerTab.Edit)
        } catch (e: Throwable) {
            errorMessage = e.message ?: e.javaClass.simpleName
        } finally {
            loading = false
        }
    }

    suspend fun save(endpoint: Endpoint, token: String, sessionId: String, path: String) {
        if (!canSave) return
        saving = true
        statusMessage = null
        errorMessage = null
        try {
            val ok = WorkspaceRpc.withConnection(
                endpoint = endpoint,
                token = token,
                timeoutSeconds = 20,
                send = { session -> session.send(ClientMessage.FileWrite(sessionId, path, content)) },
                match = { msg ->
                    when (msg) {
                        is ServerMessage.FileWriteResult -> if (msg.path == path) msg.ok else null
                        is ServerMessage.Error -> { errorMessage = msg.message; null }
                        else -> null
                    }
                },
            )
            if (ok) {
                originalContent = content
                statusMessage = "Saved."
            } else {
                errorMessage = "Save failed."
            }
        } catch (e: Throwable) {
            errorMessage = e.message ?: e.javaClass.simpleName
        } finally {
            saving = false
        }
    }
}
