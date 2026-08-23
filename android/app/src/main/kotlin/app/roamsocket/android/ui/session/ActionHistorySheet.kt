package app.roamsocket.android.ui.session

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette

/**
 * Modal bottom sheet showing the full ordered list of tool actions for
 * one action group. Each row is tappable to expand its captured output,
 * matching the per-tool detail view that used to be inline.
 *
 * Mirrors `ios/.../SessionActionHistoryView.ActionHistorySheet` (PR
 * #67). The Android side uses `ModalBottomSheet` with a partial detent
 * so the user can drag it down to peek at the underlying transcript
 * while reading long output.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ActionHistorySheet(
    tools: List<TranscriptItem.Tool>,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    var expanded by remember(tools) { mutableStateOf(setOf<String>()) }
    val success = tools.successCount()
    val failure = tools.failureCount()
    val inFlight = tools.inFlightCount()
    val total = tools.size

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.background,
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            // Header row: matching `SheetContainer` shape so the Done
            // button width is consistent with the other session sheets.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.Surface)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                TextButton(onClick = onDismiss) { Text("Done") }
                Spacer(Modifier.weight(1f))
                Text(
                    text = "Action history",
                    color = Palette.TextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.weight(1f))
                // Spacer to keep the title centred (matches Done width).
                TextButton(onClick = {}, enabled = false) { Text("Done") }
            }

            LazyColumn(
                modifier = Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                item {
                    SummaryHeader(
                        total = total,
                        success = success,
                        failure = failure,
                        inFlight = inFlight,
                    )
                }
                if (tools.isEmpty()) {
                    item {
                        Text(
                            text = "No actions yet.",
                            fontSize = 13.sp,
                            color = Palette.TextSecondary,
                            modifier = Modifier.padding(16.dp),
                        )
                    }
                } else {
                    items(tools, key = { it.id }) { tool ->
                        ActionHistoryRow(
                            tool = tool,
                            expanded = expanded.contains(tool.id),
                            onToggle = {
                                expanded = if (expanded.contains(tool.id)) {
                                    expanded - tool.id
                                } else {
                                    expanded + tool.id
                                }
                            },
                        )
                    }
                }
                item {
                    Text(
                        text = "Tap a row to see its captured output. Failures are highlighted in red.",
                        fontSize = 12.sp,
                        color = Palette.TextSecondary,
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun SummaryHeader(total: Int, success: Int, failure: Int, inFlight: Int) {
    Surface(
        color = Palette.Surface,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 10.dp),
        ) {
            if (success > 0) StatusPill(count = success, label = "OK", color = Palette.Success)
            if (failure > 0) StatusPill(count = failure, label = "Failed", color = Palette.Danger)
            if (inFlight > 0) StatusPill(count = inFlight, label = "Running", color = Palette.Accent)
            Spacer(Modifier.weight(1f))
            Text(
                text = "$total total",
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                color = Palette.TextTertiary,
            )
        }
    }
}

@Composable
private fun StatusPill(count: Int, label: String, color: Color) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier
            .clip(CircleShape)
            .background(color.copy(alpha = 0.15f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(color),
        )
        Text(
            text = "$count $label",
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            color = Palette.TextPrimary,
        )
    }
}

/**
 * One row in the action history sheet. Compact by default; tap to
 * expand and see the captured output, with copy-to-clipboard via a
 * long-press on the output.
 */
@Composable
private fun ActionHistoryRow(
    tool: TranscriptItem.Tool,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    val rotation by animateFloatAsState(
        targetValue = if (expanded) 90f else 0f,
        animationSpec = tween(durationMillis = 180),
        label = "row-chevron",
    )
    val statusColor = when (tool.ok) {
        true -> Palette.Success
        false -> Palette.Danger
        null -> Palette.Accent
    }
    val hasOutput = !tool.output.isNullOrEmpty()

    Surface(
        color = Palette.Surface,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(0.dp),
        ) {
            Row(
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(onClick = onToggle),
            ) {
                Icon(
                    imageVector = iconForTool(tool.tool),
                    contentDescription = null,
                    tint = statusColor,
                    modifier = Modifier
                        .padding(top = 2.dp)
                        .size(16.dp),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Text(
                        text = toolDisplayName(tool.tool),
                        fontSize = 12.sp,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.SemiBold,
                        color = Palette.TextTertiary,
                    )
                    Text(
                        text = tool.summary,
                        fontSize = 14.sp,
                        fontFamily = FontFamily.Monospace,
                        color = Palette.TextPrimary,
                    )
                }
                Icon(
                    imageVector = Icons.Outlined.ChevronRight,
                    contentDescription = null,
                    tint = Palette.TextTertiary,
                    modifier = Modifier
                        .padding(top = 4.dp)
                        .size(12.dp)
                        .rotate(rotation),
                )
            }

            AnimatedVisibility(visible = expanded) {
                if (hasOutput) {
                    val clipboard = LocalClipboardManager.current
                    val outputText = tool.output.orEmpty()
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 6.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(MaterialTheme.colorScheme.background)
                            .heightIn(max = 200.dp)
                            .clickable {
                                clipboard.setText(AnnotatedString(outputText))
                            },
                    ) {
                        Text(
                            text = outputText.take(2_000),
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                            color = Palette.TextSecondary,
                            maxLines = 30,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(10.dp),
                        )
                    }
                } else {
                    Text(
                        text = "No output yet.",
                        fontSize = 12.sp,
                        color = Palette.TextTertiary,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }
        }
    }
}
