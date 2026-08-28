package app.roamsocket.android.ui.markdown

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.widget.TextView
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import app.roamsocket.android.ui.theme.Palette
import kotlinx.coroutines.delay

/**
 * Renders an assistant message body as markdown with snippet support.
 *
 * The iOS counterpart (`MarkdownContentView`) uses Apple's `MarkdownUI`
 * with a custom theme. This is the Android port: same surface, themed to
 * match `Palette` (cool blue-grey / accent).
 *
 * Fenced `markdown` / `html` blocks are lifted out so they can be rendered
 * as raw source with a Preview button. Every other fenced code block is
 * rendered as its own card with a header (language label + Copy) and a
 * syntax-highlighted body. The body is coloured by a small inline
 * regex-based highlighter (see [CodeColorizer]) that handles the common
 * languages. Unknown languages still render as styled monospaced text.
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
                is MessageSegment.CodeBlock -> {
                    CodeBlockView(
                        language = segment.language,
                        code = segment.code,
                    )
                }
            }
        }
    }
}

// MARK: - Snippet block (markdown / html previews)

/**
 * Pill-shaped header + horizontally scrolling raw code body that mirrors
 * the iOS `SnippetBlock`. Tapping the Preview capsule opens the matching
 * preview sheet (markdown → [MarkdownPreviewSheet], html →
 * [HTMLPreviewSheet]). A Copy chip sits next to it so the user can grab
 * the source without round-tripping through the preview.
 */
@Composable
private fun SnippetBlock(
    kind: SnippetKind,
    language: String,
    code: String,
) {
    var showPreview by rememberSaveable { mutableStateOf(false) }

    CodeCard {
        Column {
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
                CopyChip(code = code)
                Spacer(modifier = Modifier.width(8.dp))
                PreviewCapsule(
                    kind = kind,
                    onClick = { showPreview = true },
                )
            }
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

// MARK: - Code block (generic, with header + Copy + syntax highlight)

/**
 * Generic fenced code block lifted out of the markdown body. Header shows
 * the detected language label and a Copy button. The body is coloured
 * with a small inline regex-based highlighter so common languages get
 * keyword / string / comment / number colours without pulling in the
 * full `prism4j-bundler` annotation-processor chain.
 */
@Composable
fun CodeBlockView(
    language: String,
    code: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val styled = remember(code, language) {
        CodeColorizer.colorize(code, language)
    }

    CodeCard(modifier = modifier) {
        Column {
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
                CopyChip(code = code)
            }
            AndroidView(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.Surface)
                    .horizontalScroll(rememberScrollState()),
                factory = { ctx ->
                    TextView(ctx).apply {
                        setText(styled, TextView.BufferType.SPANNABLE)
                        setTextColor(Palette.TextPrimary.toArgb())
                        textSize = 12.5f
                        setPadding(48, 36, 48, 36)
                        isVerticalScrollBarEnabled = false
                        isHorizontalScrollBarEnabled = true
                    }
                },
                update = { tv ->
                    tv.setText(styled, TextView.BufferType.SPANNABLE)
                    tv.setTextColor(Palette.TextPrimary.toArgb())
                },
            )
        }
    }
}

// MARK: - Card chrome

@Composable
private fun CodeCard(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = Palette.Surface,
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(
            width = 1.dp,
            brush = SolidColor(Palette.Separator.copy(alpha = 0.6f)),
        ),
    ) {
        content()
    }
}

// MARK: - Header actions

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

/**
 * Copy-to-clipboard chip. Mirrors the iOS `CopyButton`: shows a checkmark
 * and the word "Copied" for ~1.4s after a successful copy, then reverts.
 */
@Composable
private fun CopyChip(code: String) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }

    Surface(
        onClick = {
            copyToClipboard(context, code)
            copied = true
        },
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
                imageVector = if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = if (copied) "Copied" else "Copy",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1400)
            copied = false
        }
    }
}

private fun copyToClipboard(context: Context, text: String) {
    val payload = if (text.isEmpty()) " " else text
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
    cm?.setPrimaryClip(ClipData.newPlainText("RoamSocket code", payload))
}

// MARK: - Inline syntax colorizer

/**
 * Small regex-based highlighter for fenced code blocks. Covers the common
 * languages with keyword / string / comment / number spans. The colour
 * palette mirrors the iOS atom-one-dark theme so the two apps look the
 * same in the chat transcript. Returns a [Spannable] ready to be set on
 * a [TextView].
 *
 * The class is intentionally regex-based (no full PrismJS grammars) so we
 * don't have to wire up the ksp-driven `prism4j-bundler` annotation
 * processor just to colour the chat transcript. When a more accurate
 * highlighter is needed, swap this for a `Prism4jSyntaxHighlight` driven
 * by a full `Prism4j` grammar locator.
 */
internal object CodeColorizer {
    private val KEYWORD = buildKeywordSet()
    private val COMMENT_LINE = Regex("""//.*$""", RegexOption.MULTILINE)
    private val COMMENT_BLOCK = Regex("""/\*[\s\S]*?\*/""")
    private val COMMENT_HASH = Regex("""#.*$""", RegexOption.MULTILINE)
    private val STRING_DOUBLE = Regex(""""(?:\\.|[^"\\\n])*"""")
    private val STRING_SINGLE = Regex("""'(?:\\.|[^'\\\n])*'""")
    private val STRING_BACKTICK = Regex("""`(?:\\.|[^`\\])*`""")
    private val NUMBER = Regex("""\b\d+(?:\.\d+)?\b""")
    private val IDENT = Regex("""\b[A-Za-z_][A-Za-z0-9_]*\b""")

    fun colorize(code: String, language: String): Spannable {
        if (code.isEmpty()) return SpannableStringBuilder(" ")
        val builder = SpannableStringBuilder(code)
        val lang = language.trim().lowercase()
        val isCommentHash = lang in HASH_COMMENT_LANGS
        val keywords = KEYWORD[lang] ?: emptySet()

        applyPattern(builder, COMMENT_BLOCK, CodeColors.Comment)
        if (isCommentHash) {
            applyPattern(builder, COMMENT_HASH, CodeColors.Comment)
        } else {
            applyPattern(builder, COMMENT_LINE, CodeColors.Comment)
        }
        applyPattern(builder, STRING_DOUBLE, CodeColors.String)
        applyPattern(builder, STRING_SINGLE, CodeColors.String)
        applyPattern(builder, STRING_BACKTICK, CodeColors.String)
        applyPattern(builder, NUMBER, CodeColors.Number)

        if (keywords.isNotEmpty()) {
            applyIdentifierKeywords(builder, keywords)
        }

        return builder
    }

    private fun applyPattern(
        builder: SpannableStringBuilder,
        regex: Regex,
        color: Int,
    ) {
        for (match in regex.findAll(builder.toString())) {
            val start = match.range.first.coerceAtLeast(0)
            val end = match.range.last + 1
            builder.setSpan(
                ForegroundColorSpan(color),
                start,
                end.coerceAtMost(builder.length),
                Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
        }
    }

    private fun applyIdentifierKeywords(
        builder: SpannableStringBuilder,
        keywords: Set<String>,
    ) {
        val source = builder.toString()
        for (match in IDENT.findAll(source)) {
            val word = match.value
            if (word.lowercase() !in keywords) continue
            val start = match.range.first.coerceAtLeast(0)
            val end = (match.range.last + 1).coerceAtMost(builder.length)
            builder.setSpan(
                ForegroundColorSpan(CodeColors.Keyword),
                start,
                end,
                Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
        }
    }

    private fun buildKeywordSet(): Map<String, Set<String>> = mapOf(
        "swift" to KEYWORDS_SWIFT,
        "kotlin" to KEYWORDS_KOTLIN,
        "kt" to KEYWORDS_KOTLIN,
        "kts" to KEYWORDS_KOTLIN,
        "java" to KEYWORDS_JAVA,
        "javascript" to KEYWORDS_JS,
        "js" to KEYWORDS_JS,
        "jsx" to KEYWORDS_JS,
        "typescript" to KEYWORDS_JS + KEYWORDS_TS,
        "ts" to KEYWORDS_JS + KEYWORDS_TS,
        "tsx" to KEYWORDS_JS + KEYWORDS_TS,
        "python" to KEYWORDS_PY,
        "py" to KEYWORDS_PY,
        "go" to KEYWORDS_GO,
        "rust" to KEYWORDS_RUST,
        "rs" to KEYWORDS_RUST,
        "ruby" to KEYWORDS_RUBY,
        "rb" to KEYWORDS_RUBY,
        "bash" to KEYWORDS_BASH,
        "sh" to KEYWORDS_BASH,
        "shell" to KEYWORDS_BASH,
        "zsh" to KEYWORDS_BASH,
        "sql" to KEYWORDS_SQL,
    )

    private val HASH_COMMENT_LANGS = setOf(
        "python", "py", "ruby", "rb", "bash", "sh", "shell", "zsh", "yaml", "yml",
    )

    private val KEYWORDS_SWIFT = setOf(
        "func", "let", "var", "if", "else", "guard", "return", "for", "in",
        "while", "switch", "case", "default", "break", "continue", "class",
        "struct", "enum", "protocol", "extension", "init", "deinit", "self",
        "Self", "true", "false", "nil", "throws", "throw", "try", "catch",
        "do", "import", "public", "private", "internal", "fileprivate", "open",
        "static", "final", "mutating", "nonmutating", "weak", "unowned",
        "async", "await", "actor", "typealias", "where", "associatedtype",
        "inout", "rethrows", "defer", "repeat", "fallthrough", "as", "is",
    )
    private val KEYWORDS_KOTLIN = setOf(
        "fun", "val", "var", "if", "else", "when", "for", "while", "do",
        "return", "class", "object", "interface", "enum", "sealed", "data",
        "open", "abstract", "override", "public", "private", "internal",
        "protected", "suspend", "inline", "noinline", "crossinline",
        "companion", "init", "constructor", "this", "super", "true", "false",
        "null", "is", "as", "in", "out", "typealias", "import", "package",
        "throw", "throws", "try", "catch", "finally", "by", "lateinit",
        "const", "operator", "infix", "tailrec", "vararg", "where",
    )
    private val KEYWORDS_JAVA = setOf(
        "public", "private", "protected", "static", "final", "abstract",
        "class", "interface", "enum", "extends", "implements", "new",
        "return", "if", "else", "for", "while", "do", "switch", "case",
        "default", "break", "continue", "try", "catch", "finally",
        "throw", "throws", "import", "package", "void", "boolean", "int",
        "long", "double", "float", "char", "byte", "short", "this", "super",
        "null", "true", "false", "instanceof", "synchronized", "volatile",
        "transient", "native", "strictfp",
    )
    private val KEYWORDS_JS = setOf(
        "function", "return", "if", "else", "for", "while", "do", "switch",
        "case", "default", "break", "continue", "var", "let", "const",
        "class", "extends", "new", "this", "super", "import", "export",
        "from", "as", "async", "await", "yield", "try", "catch", "finally",
        "throw", "of", "in", "typeof", "instanceof", "void", "delete",
        "null", "true", "false", "undefined",
    )
    private val KEYWORDS_TS = setOf(
        "interface", "type", "enum", "namespace", "declare", "readonly",
        "keyof", "infer", "never", "unknown", "any", "as", "satisfies",
    )
    private val KEYWORDS_PY = setOf(
        "def", "class", "if", "elif", "else", "for", "while", "in", "not",
        "and", "or", "is", "return", "yield", "import", "from", "as",
        "with", "try", "except", "finally", "raise", "pass", "break",
        "continue", "lambda", "global", "nonlocal", "True", "False", "None",
        "self", "cls", "async", "await",
    )
    private val KEYWORDS_GO = setOf(
        "package", "import", "func", "return", "var", "const", "type",
        "struct", "interface", "map", "chan", "go", "defer", "select",
        "case", "default", "switch", "if", "else", "for", "range",
        "break", "continue", "fallthrough", "goto", "true", "false",
        "nil", "iota",
    )
    private val KEYWORDS_RUST = setOf(
        "fn", "let", "mut", "const", "static", "struct", "enum", "trait",
        "impl", "pub", "mod", "use", "as", "if", "else", "match", "for",
        "while", "loop", "return", "break", "continue", "in", "where",
        "self", "Self", "true", "false", "ref", "move", "async", "await",
        "dyn", "type", "unsafe", "extern", "crate", "super",
    )
    private val KEYWORDS_RUBY = setOf(
        "def", "end", "class", "module", "if", "elsif", "else", "unless",
        "case", "when", "while", "until", "for", "in", "do", "begin",
        "rescue", "ensure", "raise", "return", "yield", "break", "next",
        "redo", "retry", "self", "nil", "true", "false", "and", "or",
        "not", "then", "do", "lambda", "proc",
    )
    private val KEYWORDS_BASH = setOf(
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while",
        "until", "do", "done", "function", "return", "exit", "break",
        "continue", "in", "shift", "export", "local", "readonly", "set",
        "unset", "echo", "printf", "read", "trap",
    )
    private val KEYWORDS_SQL = setOf(
        "select", "from", "where", "join", "left", "right", "inner",
        "outer", "on", "as", "and", "or", "not", "null", "is", "in",
        "between", "like", "order", "by", "group", "having", "limit",
        "offset", "insert", "into", "values", "update", "set", "delete",
        "create", "table", "drop", "alter", "add", "column", "primary",
        "key", "foreign", "references", "index", "view", "with", "union",
        "all", "distinct", "case", "when", "then", "else", "end",
    )
}

/**
 * Atom-one-dark inspired palette so the highlighted blocks match the iOS
 * surface treatment. Values are pre-blended `Int` colours so the
 * [ForegroundColorSpan] setter stays a one-liner.
 */
private object CodeColors {
    val Keyword: Int = Color.parseColor("#C678DD") // purple — keyword / type
    val String: Int = Color.parseColor("#98C379") // green — string
    val Comment: Int = Color.parseColor("#5C6370") // grey — comment
    val Number: Int = Color.parseColor("#D19A66") // orange — number / literal
}
