package app.roamsocket.android.ui.markdown

import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.method.LinkMovementMethod
import android.text.style.ClickableSpan
import android.view.View
import android.widget.TextView
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import app.roamsocket.android.ui.theme.Palette
import io.noties.markwon.AbstractMarkwonPlugin
import io.noties.markwon.Markwon
import io.noties.markwon.core.MarkwonTheme
import io.noties.markwon.ext.strikethrough.StrikethroughPlugin
import io.noties.markwon.ext.tables.TablePlugin
import io.noties.markwon.ext.tasklist.TaskListPlugin
import io.noties.markwon.html.HtmlPlugin
import io.noties.markwon.linkify.LinkifyPlugin

/**
 * Renders a CommonMark / GitHub-Flavored-Markdown string as styled
 * Compose text via Markwon (the same library used by Tachiyomi,
 * Markor, and many other production Android apps).
 *
 * The iOS `MarkdownContentView` uses Apple's `MarkdownUI` with a custom
 * theme. This is the Android port: same Markdown surface, themed to
 * match `Palette` (cool blue-grey / accent `#6AA9FF`).
 *
 * Plugins enabled:
 *  - tables (GFM)
 *  - strikethrough (GFM)
 *  - task lists (GFM `- [ ]` / `- [x]`)
 *  - linkify for plain-URL autolinking
 *  - inline HTML pass-through (`<sub>`, `<sup>`, `<b>`, …)
 */
@Composable
fun MarkdownText(
    markdown: String,
    modifier: Modifier = Modifier,
    @Suppress("UNUSED_PARAMETER") fontSize: TextUnit = 16.sp,
    onLinkClick: ((String) -> Unit)? = null,
) {
    val context = LocalContext.current
    val markwon = remember(context) { buildMarkwon(context) }
    val styled = remember(markdown, markwon) { markwon.toMarkdown(markdown) }

    AndroidView(
        modifier = modifier.fillMaxWidth(),
        factory = { ctx ->
            TextView(ctx).apply {
                setText(styled, TextView.BufferType.SPANNABLE)
                // Allow the user to long-press and drag to select any
                // portion of the assistant reply — same as the user-message
                // bubble. LinkMovementMethod still handles clicks on URL
                // spans; text selection runs on the same TextView
                // independently of the movement method on modern Android.
                setTextIsSelectable(true)
                movementMethod = LinkMovementMethod.getInstance()
                if (onLinkClick != null) {
                    // Strip the default URL span and re-attach a custom click
                    // span so the caller can route links without leaving the
                    // app (e.g. into the in-app browser in a later PR).
                    val spannable = (text as? Spanned) ?: return@apply
                    val urlSpans = spannable.getSpans(0, spannable.length, android.text.style.URLSpan::class.java)
                    val builder = SpannableStringBuilder(spannable)
                    for (span in urlSpans) {
                        val start = builder.getSpanStart(span)
                        val end = builder.getSpanEnd(span)
                        val url = span.url
                        builder.removeSpan(span)
                        if (start >= 0 && end >= 0) {
                            builder.setSpan(
                                object : ClickableSpan() {
                                    override fun onClick(widget: View) {
                                        onLinkClick(url)
                                    }
                                },
                                start,
                                end,
                                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                            )
                        }
                    }
                    setText(builder, TextView.BufferType.SPANNABLE)
                }
            }
        },
        update = { textView ->
            textView.setText(styled, TextView.BufferType.SPANNABLE)
            textView.setTextIsSelectable(true)
        },
    )
}

private fun buildMarkwon(context: android.content.Context): Markwon {
    return Markwon.builder(context)
        .usePlugin(StrikethroughPlugin.create())
        .usePlugin(TablePlugin.create(context))
        .usePlugin(TaskListPlugin.create(context))
        .usePlugin(LinkifyPlugin.create())
        .usePlugin(HtmlPlugin.create())
        .usePlugin(object : AbstractMarkwonPlugin() {
            override fun configureTheme(builder: MarkwonTheme.Builder) {
                // Align the Markwon palette with the iOS MarkdownContentView
                // theme tokens (cool blue-grey, accent on links).
                val onSurface = Palette.TextPrimary.toArgb()
                val accent = Palette.Accent.toArgb()
                val codeBg = Palette.SurfaceVariant.toArgb()
                val codeFg = Palette.CodeToken.toArgb()
                builder
                    .linkColor(accent)
                    .codeTextColor(codeFg)
                    .codeBackgroundColor(codeBg)
                    .codeBlockTextColor(onSurface)
                    .codeBlockBackgroundColor(codeBg)
                    .blockQuoteColor(accent)
                    .listItemColor(onSurface)
                    .thematicBreakColor(Palette.Separator.toArgb())
            }
        })
        .build()
}
