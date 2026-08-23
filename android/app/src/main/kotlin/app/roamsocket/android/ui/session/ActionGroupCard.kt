package app.roamsocket.android.ui.session

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette

/**
 * Collapsed card that represents one or more tool actions taken by the
 * agent. Shows the count, the most recent action's summary, and
 * aggregate status badges. Tapping the card opens the full history in
 * [ActionHistorySheet].
 *
 * Mirrors `ios/.../SessionActionHistoryView.ActionGroupCard` (PR #67).
 */
@Composable
fun ActionGroupCard(
    tools: List<TranscriptItem.Tool>,
    onOpenHistory: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val last = tools.lastOrNull()
    val inFlight = tools.inFlightCount()
    val success = tools.successCount()
    val failure = tools.failureCount()
    val isLive = inFlight > 0
    val lastStatusColor = statusColor(last?.ok, isLive)
    val lastToolName = last?.tool ?: "tool"
    val lastSummary = last?.summary.orEmpty()
    val lastIcon = iconForTool(lastToolName)
    val titleText = if (tools.size == 1) "1 action" else "${tools.size} actions"

    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(12.dp),
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onOpenHistory),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
        ) {
            IconBlock(icon = lastIcon, tint = lastStatusColor)
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        text = titleText,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Palette.TextPrimary,
                    )
                    if (isLive) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(12.dp),
                            strokeWidth = 1.5.dp,
                            color = Palette.Accent,
                        )
                    }
                }
                Text(
                    text = lastSummary.ifEmpty { " " },
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace,
                    color = Palette.TextSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            TrailingBadges(failure = failure, success = success, isLive = isLive)
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
private fun IconBlock(icon: ImageVector, tint: Color) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(32.dp)
            .clip(CircleShape)
            .background(Palette.SurfaceElevated),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(16.dp),
        )
    }
}

@Composable
private fun TrailingBadges(failure: Int, success: Int, isLive: Boolean) {
    when {
        failure > 0 -> Badge(count = failure, color = Palette.Danger)
        success > 0 && !isLive -> Badge(count = success, color = Palette.Success)
        else -> Spacer(Modifier.width(0.dp))
    }
}

@Composable
private fun Badge(count: Int, color: Color) {
    Text(
        text = count.toString(),
        fontSize = 11.sp,
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Bold,
        color = color,
        modifier = Modifier
            .clip(CircleShape)
            .background(color.copy(alpha = 0.15f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

private fun statusColor(ok: Boolean?, isLive: Boolean): Color = when {
    ok == true -> Palette.Success
    ok == false -> Palette.Danger
    isLive -> Palette.Accent
    else -> Palette.TextSecondary
}

/**
 * SF Symbol → Material Icons counterpart for each supported tool name.
 * Keeps the icon block honest about what kind of action just ran
 * (terminal for bash, doc for file reads, folder for lists, etc.).
 *
 * Mirrors `ios/.../ActionGroupCard.icon(for:)` in PR #67.
 */
internal fun iconForTool(tool: String): ImageVector = when (tool) {
    "bash", "shell", "exec" -> Icons.Outlined.Terminal
    "read_file" -> Icons.Outlined.Description
    "write_file", "edit_file", "create_file", "patch" -> Icons.Outlined.Edit
    "list_files", "list_dir" -> Icons.Outlined.Folder
    "grep", "search", "ripgrep" -> Icons.Outlined.Search
    "web_search", "web_fetch" -> Icons.Outlined.Public
    "git" -> Icons.Outlined.AccountTree
    "skill", "skills" -> Icons.Outlined.AutoAwesome
    "mcp", "mcp_call" -> Icons.Outlined.Extension
    else -> Icons.Outlined.Build
}

/** Human-readable tool label (e.g. "Bash", "File") for the action history rows. */
internal fun toolDisplayName(tool: String): String = when (tool) {
    "bash", "shell", "exec" -> "Bash"
    "read_file", "write_file", "edit_file", "create_file", "patch" -> "File"
    "list_files", "list_dir" -> "List"
    "grep", "search", "ripgrep" -> "Search"
    "web_search" -> "Web search"
    "web_fetch" -> "Web fetch"
    "git" -> "Git"
    else -> tool
}
