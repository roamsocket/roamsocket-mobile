package app.roamsocket.android.ui.markdown

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette

/**
 * Renders an assistant message body as markdown with snippet support.
 *
 * The iOS counterpart (`MarkdownContentView`) uses Apple's `MarkdownUI`
 * with a custom `anyProv` theme. The Android port reuses the existing
 * Markwon-backed [MarkdownText] for the prose and adds a fenced-block
 * pre-segmenter that lifts `markdown` / `html` code fences out of the
 * markdown body so they can be rendered as raw source with a Preview
 * button.
 *
 * The output is a vertical column of segments spaced 12.dp apart, which
 * matches the iOS `VStack(spacing: 12)`.
 */
@Composable
fun MarkdownContentView(
    text: String,
    modifier: Modifier = Modifier,
    fontSize: TextUnit = 16.sp,
    onLinkClick: ((String) -> Unit)? = null,
) {
    val segments = remember(text) { MessageSegmentParser.parse(text) }
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        segments.forEach { segment ->
            when (segment) {
                is MessageSegment.MarkdownBody -> {
                    if (segment.text.isBlank()) return@forEach
                    MarkdownText(
                        markdown = segment.text,
                        modifier = Modifier.fillMaxWidth(),
                        fontSize = fontSize,
                        onLinkClick = onLinkClick,
                    )
                }
                is MessageSegment.SnippetBlock -> {
                    SnippetBlock(
                        kind = segment.kind,
                        language = segment.language,
                        code = segment.code,
                    )
                }
            }
        }
    }
}

/**
 * Pill-shaped header + horizontally scrolling raw code body that
 * mirrors the iOS `SnippetBlock`. Tapping the capsule opens the
 * matching preview sheet (markdown → [MarkdownPreviewSheet],
 * html → [HTMLPreviewSheet]).
 */
@Composable
private fun SnippetBlock(
    kind: SnippetKind,
    language: String,
    code: String,
) {
    var showPreview by rememberSaveable { mutableStateOf(false) }

    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = Palette.Surface,
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(
            width = 1.dp,
            brush = SolidColor(Palette.Separator.copy(alpha = 0.6f)),
        ),
    ) {
        Column {
            // Header row: language label on the left, Preview capsule on
            // the right. Matches the iOS HStack(spacing: 8) over a
            // surfaceElevated background.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.SurfaceElevated)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = language.uppercase(),
                    color = Palette.TextTertiary,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = true),
                )
                PreviewCapsule(
                    kind = kind,
                    onClick = { showPreview = true },
                )
            }
            // Raw code body. Horizontal scroll for long lines; one
            // trailing space keeps an empty snippet visually rendered
            // (mirrors the iOS `code.isEmpty ? " " : code`).
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.Surface)
                    .horizontalScroll(rememberScrollState())
                    .padding(12.dp),
            ) {
                Text(
                    text = if (code.isEmpty()) " " else code,
                    color = Palette.TextPrimary,
                    fontSize = 12.5.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
    }

    if (showPreview) {
        when (kind) {
            SnippetKind.MARKDOWN -> MarkdownPreviewSheet(
                markdown = code,
                onDismiss = { showPreview = false },
            )
            SnippetKind.HTML -> HTMLPreviewSheet(
                html = code,
                title = "HTML preview",
                onDismiss = { showPreview = false },
            )
        }
    }
}

@Composable
private fun PreviewCapsule(kind: SnippetKind, onClick: () -> Unit) {
    val (icon, label) = when (kind) {
        SnippetKind.MARKDOWN -> Icons.Outlined.Visibility to "Preview"
        SnippetKind.HTML -> Icons.Outlined.OpenInNew to "Preview in browser"
    }
    Surface(
        onClick = onClick,
        color = Palette.Accent.copy(alpha = 0.14f),
        contentColor = Palette.Accent,
        shape = RoundedCornerShape(50),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = label,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}
