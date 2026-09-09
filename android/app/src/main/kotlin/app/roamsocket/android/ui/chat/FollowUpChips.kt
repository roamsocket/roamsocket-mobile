package app.roamsocket.android.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Horizontally-scrolling row of follow-up suggestion chips.
 *
 * Renders below the assistant bubble in the chat composer and in
 * the E2B session's input area. Tap hands the label back to the
 * parent for the next user turn. Mirrors the iOS
 * `FollowUpChips.swift` contract 1:1 (same max 8 chips, same
 * label cap, same theming via the surface container + accent
 * arrow).
 *
 * The iOS version lives at
 * `ios/App/Sources/Features/Chat/FollowUpChips.swift`. Both share
 * the same `FollowUpExtractor` so the labels rendered here are
 * the same set the iOS side would render for the same input.
 */
@Composable
fun FollowUpChips(
    suggestions: List<String>,
    onPick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (suggestions.isEmpty()) return
    val scrollState = rememberScrollState()
    Row(
        modifier = modifier
            .horizontalScroll(scrollState)
            .padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for (label in suggestions) {
            FollowUpChip(label = label, onClick = { onPick(label) })
        }
    }
}

@Composable
private fun FollowUpChip(
    label: String,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(percent = 50)
    val container = MaterialTheme.colorScheme.surfaceVariant
    val border = MaterialTheme.colorScheme.outline.copy(alpha = 0.7f)
    val accent = MaterialTheme.colorScheme.primary
    Row(
        modifier = Modifier
            .clip(shape)
            .background(container)
            .border(width = 1.dp, color = border, shape = shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .semantics { contentDescription = "Send: $label" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            imageVector = Icons.AutoMirrored.Outlined.ArrowForward,
            contentDescription = null,
            tint = accent,
            modifier = Modifier
                .padding(0.dp)
                .then(Modifier)
        )
        Text(
            text = label,
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Start,
            maxLines = 2,
        )
    }
}
