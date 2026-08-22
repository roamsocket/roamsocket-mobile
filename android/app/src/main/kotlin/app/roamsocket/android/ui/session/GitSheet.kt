package app.roamsocket.android.ui.session

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.code.SessionTranscriptLine
import app.roamsocket.core.protocol.ClientMessage
import app.roamsocket.core.protocol.ServerMessage
import app.roamsocket.core.server.Endpoint
import app.roamsocket.core.server.WorkspaceRpc
import kotlinx.coroutines.launch

/**
 * Git publish sheet — instant commit / push / PR flow. Mirrors the
 * iOS `gitSheet` in `ios/.../SessionView.swift`.
 *
 * Wire: a single `git_publish` message with the chosen [GitAction]'s
 * bitmask. The server runs the steps and replies with `git_result` /
 * `pr_created`.
 */
@Composable
fun GitSheet(
    action: GitAction,
    sessionId: String,
    endpoint: Endpoint?,
    token: String?,
    firstUserMessage: String?,
    transcript: List<SessionTranscriptLine>,
    diffSummary: String?,
    diffStats: DiffStats,
    onDismiss: () -> Unit,
    onPublished: (prUrl: String?) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var commitMessage by remember { mutableStateOf("") }
    var generating by remember { mutableStateOf(action.needsMessage) }
    var publishing by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var statusMessage by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(action) {
        if (action.needsMessage && commitMessage.isEmpty()) {
            commitMessage = CommitMessageGenerator.suggest(
                firstUserMessage = firstUserMessage,
                diffSummary = diffSummary,
                transcript = transcript,
                diffStats = diffStats,
            )
            generating = false
        }
    }

    val canPublish = !publishing &&
        (!action.needsMessage || commitMessage.trim().isNotEmpty()) &&
        endpoint != null && !token.isNullOrEmpty()

    Surface(
        color = MaterialTheme.colorScheme.background,
        modifier = Modifier
            .fillMaxSize()
            .imePadding()
            .navigationBarsPadding(),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.Surface)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                TextButton(onClick = onDismiss, enabled = !publishing) { Text("Cancel") }
                Spacer(Modifier.weight(1f))
                Text(
                    text = action.title,
                    color = Palette.TextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.weight(1f))
                Button(
                    onClick = {
                        if (canPublish) {
                            publishing = true
                            errorMessage = null
                            statusMessage = null
                            scope.launch {
                                publish(
                                    endpoint = endpoint!!,
                                    token = token!!,
                                    sessionId = sessionId,
                                    action = action,
                                    message = commitMessage,
                                    onResult = { ok, detail ->
                                        publishing = false
                                        if (ok) {
                                            statusMessage = detail ?: action.title
                                            onPublished(null) // PR URL is delivered by `pr_created`, not here.
                                        } else {
                                            errorMessage = detail ?: "Action failed."
                                        }
                                    },
                                )
                            }
                        }
                    },
                    enabled = canPublish,
                ) {
                    if (publishing) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(14.dp),
                            strokeWidth = 1.5.dp,
                            color = MaterialTheme.colorScheme.onPrimary,
                        )
                    } else {
                        Text(action.title)
                    }
                }
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (action.needsMessage) {
                    Text(
                        text = "Commit message",
                        color = Palette.TextSecondary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(Palette.Surface)
                            .padding(12.dp),
                    ) {
                        if (commitMessage.isEmpty() && generating) {
                            Text(
                                text = "Generating commit message…",
                                color = Palette.TextTertiary,
                                fontSize = 14.sp,
                            )
                        } else {
                            BasicTextField(
                                value = commitMessage,
                                onValueChange = { commitMessage = it },
                                textStyle = TextStyle(
                                    color = Palette.TextPrimary,
                                    fontSize = 15.sp,
                                ),
                                cursorBrush = SolidColor(Palette.Accent),
                                minLines = 2,
                                maxLines = 6,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TextButton(
                            onClick = {
                                generating = true
                                commitMessage = ""
                                // Heuristic regen — fast, no AI.
                                commitMessage = CommitMessageGenerator.suggest(
                                    firstUserMessage = firstUserMessage,
                                    diffSummary = diffSummary,
                                    transcript = transcript,
                                    diffStats = diffStats,
                                )
                                generating = false
                            },
                            enabled = !publishing,
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.AutoAwesome,
                                contentDescription = null,
                                tint = Palette.Accent,
                                modifier = Modifier.size(14.dp),
                            )
                            Spacer(Modifier.size(4.dp))
                            Text("Regenerate")
                        }
                    }
                } else {
                    Text(
                        text = "Pushes the current work branch to origin.",
                        color = Palette.TextSecondary,
                        fontSize = 13.sp,
                    )
                }
                if (diffStats.added > 0 || diffStats.removed > 0) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = "Local changes",
                            color = Palette.TextSecondary,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.size(6.dp))
                        Text(
                            text = "+${diffStats.added} -${diffStats.removed}",
                            color = Palette.Accent,
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
                statusMessage?.let { msg ->
                    Text(
                        text = msg,
                        color = Palette.Accent,
                        fontSize = 12.sp,
                    )
                }
                errorMessage?.let { err ->
                    Text(
                        text = err,
                        color = MaterialTheme.colorScheme.error,
                        fontSize = 12.sp,
                    )
                }
            }
        }
    }
}

/** Mirrors iOS `GitSheetAction`. */
enum class GitAction(
    val title: String,
    val commit: Boolean,
    val push: Boolean,
    val openPr: Boolean,
) {
    Commit("Commit", commit = true, push = false, openPr = false),
    Push("Push", commit = false, push = true, openPr = false),
    Pr("Create PR", commit = true, push = true, openPr = true),
    All("Done · Commit · Push · PR", commit = true, push = true, openPr = true);

    val needsMessage: Boolean get() = commit
}

private suspend fun publish(
    endpoint: Endpoint,
    token: String,
    sessionId: String,
    action: GitAction,
    message: String,
    onResult: (ok: Boolean, detail: String?) -> Unit,
) {
    try {
        val ok = WorkspaceRpc.withConnection(
            endpoint = endpoint,
            token = token,
            timeoutSeconds = 30,
            send = { session ->
                session.send(
                    ClientMessage.GitPublish(
                        sessionId = sessionId,
                        message = message,
                        commit = action.commit,
                        push = action.push,
                        openPr = action.openPr,
                    ),
                )
            },
            match = { msg ->
                when (msg) {
                    is ServerMessage.GitResult -> {
                        // action echoes the step; success returns immediately so the
                        // iOS sheet can dismiss without waiting for pr_created.
                        onResult(msg.ok, msg.detail)
                        msg.ok
                    }
                    is ServerMessage.Error -> { onResult(false, msg.message); false }
                    else -> null
                }
            },
        )
        if (!ok) onResult(false, "Desktop did not acknowledge the publish.")
    } catch (e: Throwable) {
        onResult(false, e.message ?: e.javaClass.simpleName)
    }
}
