package app.roamsocket.android.ui.browser

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Bookmarks + history list. Mirrors the iOS `BookmarksSheet` portion of
 * `BrowserView.swift` — same two-section layout (Bookmarks, Recent)
 * with a clear-history button.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookmarksSheet(
    store: BrowserStore,
    bookmarks: List<BrowserBookmark>,
    history: List<BrowserHistoryEntry>,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.background,
        dragHandle = null,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    "Bookmarks",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                TextButton(onClick = onDismiss) {
                    Text("Done", color = MaterialTheme.colorScheme.primary)
                }
            }
            LazyColumn(modifier = Modifier.fillMaxSize().padding(horizontal = 14.dp)) {
                item {
                    Text(
                        "Bookmarks",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 8.dp),
                    )
                }
                if (bookmarks.isEmpty()) {
                    item {
                        Text(
                            "No bookmarks yet",
                            fontSize = 13.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(vertical = 4.dp),
                        )
                    }
                } else {
                    items(bookmarks, key = { it.id }) { bookmark ->
                        HistoryOrBookmarkRow(
                            title = bookmark.title.ifEmpty { bookmark.url },
                            subtitle = bookmark.url,
                            onClick = { store.openBookmark(bookmark) },
                            onDelete = { store.removeBookmark(bookmark.id) },
                        )
                    }
                }
                item {
                    Text(
                        "Recent",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 8.dp),
                    )
                }
                items(history.take(30), key = { it.id }) { entry ->
                    HistoryOrBookmarkRow(
                        title = entry.title.ifEmpty { entry.url },
                        subtitle = entry.url,
                        onClick = { store.openFromHistory(entry) },
                    )
                }
                if (history.isNotEmpty()) {
                    item {
                        TextButton(
                            onClick = { store.clearHistory() },
                            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                        ) {
                            Text("Clear history", color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun HistoryOrBookmarkRow(
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    onDelete: (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                subtitle,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (onDelete != null) {
            IconButton(onClick = onDelete) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = "Delete",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}
