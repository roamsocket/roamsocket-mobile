package app.roamsocket.android.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * PR #80: bottom-sheet picker for message-level actions. Mirrors
 * the iOS `MessageActionsSheet` (`square.and.arrow.up` / `tray.full`
 * / `star` / `pencil` / `trash` rows) at the subset the Android
 * chat supports today:
 *
 *  * **Copy** — write the message text to the system clipboard.
 *  * **Share** — fire `Intent.ACTION_SEND` so the user can pick
 *    any installed share target.
 *  * **Delete** — drop the message from the in-memory transcript
 *    via [ChatViewModel.deleteMessage].
 *
 * The iOS-only "Add to project" / "Star" / "Rename" rows aren't
 * surfaced on Android yet — the corresponding
 * `ChatHistoryStore.setStarred` / `rename` / `addChatToProject`
 * hooks are already wired (see PR #76 sidebar map) but the iOS
 * project model itself has no Android equivalent so the rows
 * would always be no-ops. A follow-up could surface "Star" once
 * the Android sidebar adopts the same star field.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MessageActionsSheet(
    message: ChatMessage,
    onCopy: () -> Unit,
    onShare: () -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = LocalContext.current

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
            // Preview of the message the actions apply to. Mirrors
            // iOS `messagePreview` (single line, ellipsised tail).
            Text(
                text = message.text.trim().ifEmpty { "(empty)" },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
            )
            Spacer(modifier = Modifier.size(8.dp))
            ActionRow(
                icon = Icons.Outlined.ContentCopy,
                title = "Copy",
                tint = MaterialTheme.colorScheme.onSurface,
                onClick = {
                    val text = message.text.trim()
                    if (text.isNotEmpty()) {
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE)
                            as? ClipboardManager
                        clipboard?.setPrimaryClip(ClipData.newPlainText("RoamSocket", text))
                    }
                    onCopy()
                    onDismiss()
                },
            )
            ActionRow(
                icon = Icons.Outlined.Share,
                title = "Share",
                tint = MaterialTheme.colorScheme.onSurface,
                onClick = {
                    val text = message.text.trim()
                    if (text.isNotEmpty()) {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, text)
                        }
                        val chooser = Intent.createChooser(send, "Share message").apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        context.startActivity(chooser)
                    }
                    onShare()
                    onDismiss()
                },
            )
            ActionRow(
                icon = Icons.Outlined.Delete,
                title = "Delete",
                tint = MaterialTheme.colorScheme.error,
                onClick = {
                    onDelete()
                    onDismiss()
                },
            )
            // Silence the unused-arrangement warning on the import.
            @Suppress("UNUSED_EXPRESSION") Arrangement.Top
        }
    }
}

@Composable
private fun ActionRow(
    icon: ImageVector,
    title: String,
    tint: Color,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface)
            .clickable(onClick = onClick),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 14.dp),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(22.dp),
            )
            Spacer(modifier = Modifier.size(14.dp))
            Text(
                text = title,
                fontSize = 16.sp,
                fontWeight = FontWeight.Medium,
                color = tint,
            )
        }
    }
}
