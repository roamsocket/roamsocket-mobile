package app.roamsocket.android.ui.markdown

import android.annotation.SuppressLint
import android.view.ViewGroup
import android.webkit.WebView
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.roamsocket.android.ui.theme.Palette

/**
 * Full-screen rendered markdown preview. Mirrors the iOS
 * `MarkdownPreviewSheet` — a `ModalBottomSheet` on
 * [Palette.Background] with a "Markdown preview" header, a close icon
 * in the top-right, and a scrollable `MarkdownText` body.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MarkdownPreviewSheet(
    markdown: String,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Palette.Background,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            SheetHeader(title = "Markdown preview", onClose = onDismiss)
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
            ) {
                MarkdownText(markdown = markdown)
                Spacer(Modifier.padding(bottom = 16.dp))
            }
        }
    }
}

/**
 * In-app browser for HTML snippets. Mirrors the iOS `HTMLPreviewSheet`:
 * if the input already contains `<html` or `<!doctype` it is passed
 * through unchanged, otherwise it is wrapped in a dark `<html>` shell
 * with body styles that match `Palette` (cool blue-grey background,
 * accent links, monospaced pre/code with a rounded background and
 * horizontal overflow).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HTMLPreviewSheet(
    html: String,
    title: String = "Preview",
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val wrappedHtml = remember(html) { wrapHtmlIfNeeded(html) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Palette.Background,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            SheetHeader(title = title, onClose = onDismiss)
            HtmlWebView(html = wrappedHtml, modifier = Modifier.fillMaxSize())
        }
    }
}

@Composable
private fun SheetHeader(title: String, onClose: () -> Unit) {
    Surface(
        color = Palette.Background,
        contentColor = Palette.TextPrimary,
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding(),
    ) {
        androidx.compose.foundation.layout.Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = Palette.TextPrimary,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 8.dp),
            )
            IconButton(onClick = onClose) {
                Icon(
                    imageVector = Icons.Outlined.Close,
                    contentDescription = "Close",
                    tint = Palette.TextPrimary,
                )
            }
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun HtmlWebView(html: String, modifier: Modifier = Modifier) {
    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            WebView(ctx).apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
                setBackgroundColor(android.graphics.Color.parseColor("#0B0D10"))
                settings.javaScriptEnabled = true
                loadDataWithBaseURL(
                    /* baseUrl = */ null,
                    /* data = */ html,
                    /* mimeType = */ "text/html",
                    /* encoding = */ "utf-8",
                    /* historyUrl = */ null,
                )
            }
        },
        // We intentionally do not react to recompositions with a fresh
        // load — the `html` is remembered at the call site, so this
        // factory is only invoked once per sheet.
        update = { /* no-op */ },
    )
}

/**
 * Inject a dark-friendly body style when the document has no full
 * HTML shell. Mirrors iOS `HTMLWebView.wrapIfNeeded`. Colour values
 * are hard-coded hex (matching `Palette`) so the shell renders
 * correctly even before Compose has resolved the theme tokens.
 */
internal fun wrapHtmlIfNeeded(raw: String): String {
    val trimmed = raw.trim()
    val lower = trimmed.lowercase()
    if (lower.contains("<html") || lower.contains("<!doctype")) {
        return raw
    }
    return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <style>
            :root { color-scheme: dark; }
            body {
              margin: 16px;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              background: #0B0D10;
              color: #E6EAF0;
              line-height: 1.45;
            }
            a { color: #6AA9FF; }
            pre, code {
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
              background: #14181D;
              border-radius: 6px;
            }
            pre { padding: 12px; overflow-x: auto; }
            code { padding: 1px 4px; }
          </style>
        </head>
        <body>
        $raw
        </body>
        </html>
    """.trimIndent()
}
