package app.roamsocket.android.ui.artifacts

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette

/**
 * Read-only document view for a single artifact. Mirrors the iOS
 * `ArtifactDetailView`: uppercase "ARTIFACT" label, large title,
 * scrollable selectable content, and a copy-to-clipboard action.
 *
 * Ports [ArtifactDetailView] from
 * `ios/App/Sources/Features/Artifacts/ArtifactsListView.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArtifactDetailScreen(
    artifact: Artifact,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Palette.Background)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            TopAppBar(
                title = {
                    Text(
                        text = "ARTIFACT",
                        color = Palette.TextTertiary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Outlined.ArrowBack,
                            contentDescription = "Back",
                            tint = Palette.TextPrimary,
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { copyToClipboard(context, artifact.content) }) {
                        Icon(
                            imageVector = Icons.Outlined.ContentCopy,
                            contentDescription = "Copy",
                            tint = Palette.TextPrimary,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Palette.Background,
                ),
            )

            Text(
                text = artifact.title,
                color = Palette.TextPrimary,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .padding(bottom = 10.dp),
            )

            // Content scroll area — SelectionContainer lets the user
            // long-press a phrase to copy a snippet, matching iOS
            // `.textSelection(.enabled)`.
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp)
                    .padding(bottom = 24.dp),
            ) {
                SelectionContainer {
                    Text(
                        text = renderArtifactContent(artifact.content),
                        color = Palette.TextPrimary,
                        fontSize = 14.sp,
                        style = TextStyle.Default,
                    )
                }
                Spacer(modifier = Modifier.height(24.dp))
            }
        }
    }
}

/**
 * Best-effort monospace rendering for triple-backtick code blocks so
 * the artifact preview keeps the structure the assistant produced.
 * Plain text lines stay in the default font.
 */
private fun renderArtifactContent(content: String): androidx.compose.ui.text.AnnotatedString =
    buildAnnotatedString {
        var inFence = false
        for (raw in content.split('\n')) {
            if (raw.trim().startsWith("```")) {
                inFence = !inFence
                // Skip the fence line itself — it carries no content.
                continue
            }
            if (inFence) {
                withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) {
                    append(raw)
                }
            } else {
                append(raw)
            }
            append('\n')
        }
    }

private fun copyToClipboard(context: Context, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
    if (clipboard == null) {
        Toast.makeText(context, "Copy unavailable", Toast.LENGTH_SHORT).show()
        return
    }
    clipboard.setPrimaryClip(ClipData.newPlainText("artifact", text))
    Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
}
