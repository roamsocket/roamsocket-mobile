package app.roamsocket.android.ui.chat

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette

/**
 * Claude-style "thinking" row: clock on the left, grey summary, chevron on
 * the right. **No card / bubble chrome** — the row sits inline the same
 * way the iOS `ThinkingBlock` does, so a thinking turn doesn't visually
 * outweigh the assistant's actual reply.
 *
 * Tap opens a **Thought process** sheet with the full reasoning body.
 * Long-press copies the trimmed reasoning to the system clipboard (matches
 * the iOS `ThinkingBlock` long-press affordance).
 *
 * When [text] is empty (open `<think>` tag with no body yet) the static
 * "Thinking..." label is replaced by an [AssistantTypingIndicator] so raw
 * markup never leaks.
 *
 * @param text the inner reasoning body (already extracted by
 *   [ThinkingExtractor.extract]). Non-empty when the model has emitted
 *   at least one complete think block.
 * @param summary optional precomputed one-line label. When null the
 *   composable falls back to [ThinkingSummaryGenerator.heuristicSummary].
 * @param expanded when true the full reasoning body is always shown
 *   under the row. Mirrors iOS `state.alwaysExpandThinking`.
 */
@Composable
fun ThinkingBlock(
    text: String,
    modifier: Modifier = Modifier,
    summary: String? = null,
    expanded: Boolean = false,
) {
    var showSheet by remember { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current

    val hasBody = text.isNotBlank()
    val displaySummary: String = when {
        !hasBody -> "Thinking…"
        !summary.isNullOrBlank() -> summary
        else -> ThinkingSummaryGenerator.heuristicSummary(text)
    }

    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(6.dp))
                .clickable(enabled = hasBody) { showSheet = true }
                .padding(horizontal = 4.dp, vertical = 6.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Schedule,
                contentDescription = null,
                tint = Palette.TextTertiary,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(8.dp))
            if (hasBody) {
                Text(
                    text = displaySummary,
                    color = Palette.TextTertiary,
                    fontSize = 14.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
            } else {
                // Live typing wave instead of static "Thinking…" so the
                // user can see the agent is still working before any
                // tokens arrive.
                AssistantTypingIndicator()
            }
            if (hasBody) {
                Icon(
                    imageVector = Icons.Outlined.ContentCopy,
                    contentDescription = "Copy thinking",
                    tint = Palette.TextTertiary,
                    modifier = Modifier
                        .size(14.dp)
                        .clickable {
                            clipboard.setText(AnnotatedString(text.trim()))
                        },
                )
            }
        }

        if (hasBody && expanded) {
            Spacer(Modifier.height(4.dp))
            Text(
                text = text,
                color = Palette.TextTertiary,
                fontSize = 13.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 4.dp, vertical = 4.dp),
            )
        }
    }

    if (showSheet && hasBody) {
        ThoughtProcessDialog(
            text = text,
            onDismiss = { showSheet = false },
        )
    }
}

@Composable
private fun ThoughtProcessDialog(text: String, onDismiss: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
        dismissButton = {
            TextButton(onClick = {
                clipboard.setText(AnnotatedString(text.trim()))
            }) { Text("Copy") }
        },
        title = {
            Text(
                text = "Thought process",
                fontWeight = FontWeight.SemiBold,
            )
        },
        text = {
            Text(
                text = text,
                color = Palette.TextPrimary,
                fontSize = 15.sp,
            )
        },
        containerColor = Palette.Surface,
        textContentColor = Palette.TextPrimary,
        titleContentColor = Palette.TextPrimary,
    )
}

/**
 * Three bouncing dots so the user can see the AI is working before the
 * first tokens (or between tool turns). Mirrors the iOS `TypingDotsView`
 * — driven by a single infinite transition so the wave keeps running
 * through parent re-renders.
 */
@Composable
fun AssistantTypingIndicator(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "typing-dots")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1100, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "typing-phase",
    )

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = modifier,
    ) {
        for (i in 0 until 3) {
            val wave = sinWave(phase, offset = i * 0.18f)
            Box(
                modifier = Modifier
                    .size(7.dp)
                    .graphicsLayer {
                        translationY = -3.5f * wave
                        alpha = 0.30f + 0.70f * wave
                    }
                    .clip(CircleShape)
                    .background(Palette.TextSecondary),
            )
        }
    }
}

private fun sinWave(phase: Float, offset: Float): Float {
    val raw = (phase + offset) * 2f * Math.PI.toFloat()
    val s = kotlin.math.sin(raw)
    return (s + 1f) / 2f
}

/**
 * Stub kept so the symmetry with iOS `ThinkingSummaryGenerator` is
 * obvious. We don't run an on-device model on Android; the heuristic
 * alone is good enough for the collapsed-row label.
 */
private object ThinkingSummaryGenerator {
    private const val MAX_SUMMARY_LENGTH = 56

    fun heuristicSummary(thinking: String): String {
        var text = thinking
            .replace(Regex("""\s+"""), " ")
            .trim()
        if (text.isEmpty()) return "Thinking…"

        val firstBreak = text.indexOfFirst { it == '.' || it == '!' || it == '?' || it == '\n' }
        if (firstBreak > 0) {
            val sentence = text.substring(0, firstBreak).trim()
            if (sentence.length >= 12) text = sentence
        }

        if (text.length <= MAX_SUMMARY_LENGTH) return text
        val clipped = text.substring(0, MAX_SUMMARY_LENGTH - 1)
        val lastSpace = clipped.lastIndexOf(' ')
        return if (lastSpace > 0) clipped.substring(0, lastSpace) + "…" else clipped + "…"
    }
}
