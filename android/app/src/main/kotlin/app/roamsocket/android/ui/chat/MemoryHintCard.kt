package app.roamsocket.android.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.RemoveCircleOutline
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * PR #79: inline "Saved to memory" card shown beneath the
 * assistant message that triggered an auto-save. Mirrors the iOS
 * `MemoryHintCard` (1:1 layout — same icon, same "Undo" button,
 * same surface treatment).
 *
 * The card observes [MemoryStore] so a later edit on the same
 * memory keeps the label / preview in sync. Tap Undo to call
 * [MemoryStore.undoActivity] and dismiss the card.
 */
@Composable
fun MemoryHintCard(
    memory: MemoryStore,
    activityID: String,
    modifier: Modifier = Modifier,
    onUndo: (() -> Unit)? = null,
) {
    val activity by memory.activity.collectAsState()
    val row = activity.firstOrNull { it.id == activityID } ?: return

    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface,
        modifier = modifier
            .fillMaxWidth()
            .border(
                width = 1.dp,
                color = MaterialTheme.colorScheme.outlineVariant,
                shape = RoundedCornerShape(10.dp),
            ),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            Icon(
                imageVector = iconFor(row.kind),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp),
            )
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 10.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = labelFor(row),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                if (row.detailPreview.isNotEmpty()) {
                    Text(
                        text = row.detailPreview,
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                    )
                }
            }
            TextButton(
                onClick = {
                    memory.undoActivity(activityID)
                    onUndo?.invoke()
                },
                modifier = Modifier.background(
                    color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                ),
            ) {
                Text(
                    text = "Undo",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}

private fun labelFor(entry: MemoryStore.ActivityEntry): String = when (entry.kind) {
    MemoryStore.Kind.ADD -> "Saved to memory"
    MemoryStore.Kind.UPDATE -> "Updated memory"
    MemoryStore.Kind.FORGET -> "Forgot from memory"
    MemoryStore.Kind.RENAME -> "Renamed memory"
}

private fun iconFor(kind: MemoryStore.Kind): ImageVector = when (kind) {
    MemoryStore.Kind.ADD -> Icons.Outlined.CheckCircle
    MemoryStore.Kind.UPDATE -> Icons.Outlined.Edit
    MemoryStore.Kind.FORGET -> Icons.Outlined.RemoveCircleOutline
    MemoryStore.Kind.RENAME -> Icons.Outlined.Tag
}
