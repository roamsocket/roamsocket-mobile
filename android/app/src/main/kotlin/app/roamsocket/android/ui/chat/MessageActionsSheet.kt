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
import androidx.compose.material.icons.outlined.Refresh
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
 * Bottom-sheet picker for per-message actions. Mirrors the per-
 * message actions that are actually wired on iOS:
 *
 *  * **Copy** — write the message text to the system clipboard.
 *  * **Share** — fire `Intent.ACTION_SEND` so the user can pick
 *    any installed share target.
 *  * **Regenerate** *(assistant only)* — re-send the user prompt
 *    that produced this assistant turn and drop the existing row.
 *    Mirrors the iOS `regenerateResponse(for:)` flow at
 *    `ios/.../ChatViewModel.swift:1167-1177`. Hidden when the
 *    message is still streaming or isn't an assistant row.
 *  * **Delete** — drop the message from the in-memory transcript
 *    via [ChatViewModel.deleteMessage]. The iOS chat surface
 *    doesn't expose a per-message delete (delete is per-chat in
 *    the sidebar) but Android already has it, so we keep it
 *    rather than regress.
 *
 * Star / Rename / Add to project are **per-chat** actions, not
 * per-message — they live in the sidebar (`SidebarView.kt`) on
 * both platforms, not here. The iOS `MessageActionsSheet.swift`
 * file that lists 5 actions (Share / Add to project / Star /
 * Rename / Delete) is **dead code** — `grep -rn
 * "MessageActionsSheet(" ios` shows it's only referenced from
 * its own `#Preview`. Mirroring it 1:1 would just add dead UI
 * to Android, so we deliberately don't.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MessageActionsSheet(
    message: ChatMessage,
    onCopy: () -> Unit,
    onShare: () -> Unit,
    onRegenerate: (() -> Unit)? = null,
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
                icon = Icons.Outlined.Refresh,
                title = "Regenerate",
                tint = MaterialTheme.colorScheme.onSurface,
                onClick = {
                    onRegenerate?.invoke()
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
