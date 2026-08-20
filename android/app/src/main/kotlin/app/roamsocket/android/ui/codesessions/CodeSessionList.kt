package app.roamsocket.android.ui.codesessions

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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccessTime
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.code.CodeSession
import java.text.DateFormat
import java.util.Date

/**
 * The "Sessions" list shown above the paired-server card on the Code
 * tab. Mirrors the iOS `sessionCard` row in
 * `ios/App/Sources/Features/Code/CodeHomeView.swift`: title, repo
 * mono-line, status pill, relative timestamp.
 *
 * Tapping a row invokes [onOpen] so the caller can re-attach the
 * session.
 */
@Composable
fun CodeSessionList(
    sessions: List<CodeSession>,
    onOpen: (CodeSession) -> Unit,
    onArchive: (CodeSession) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        Text(
            text = "Sessions",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 4.dp, top = 8.dp, bottom = 8.dp),
        )
        if (sessions.isEmpty()) {
            EmptyState()
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(vertical = 0.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(sessions, key = { it.id }) { session ->
                    SessionRow(
                        session = session,
                        onClick = { onOpen(session) },
                        onArchive = { onArchive(session) },
                    )
                }
            }
        }
    }
}

@Composable
private fun EmptyState() {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                Icons.Outlined.PlayArrow,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(28.dp),
            )
            Text(
                text = "No sessions yet",
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Start a session once your desktop is paired — it shows up here and resumes next launch.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SessionRow(
    session: CodeSession,
    onClick: () -> Unit,
    onArchive: () -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(28.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Outlined.Code,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(14.dp),
                    )
                }
                Spacer(Modifier.size(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = session.title,
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                    )
                    Text(
                        text = "${session.repoFullName} · ${session.workBranch}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1,
                    )
                }
                StatusPill(status = session.status)
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Outlined.AccessTime,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(12.dp),
                )
                Spacer(Modifier.size(4.dp))
                Text(
                    text = formatRelativeTime(session.updatedAtMillis),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                if (session.status != CodeSession.Status.ARCHIVED) {
                    Text(
                        text = "Archive",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.primary,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier
                            .clip(androidx.compose.foundation.shape.RoundedCornerShape(50))
                            .clickable(onClick = onArchive)
                            .padding(horizontal = 10.dp, vertical = 4.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun StatusPill(status: CodeSession.Status) {
    val (icon: ImageVector, label: String, tint: Color) = when (status) {
        CodeSession.Status.WORKING -> Triple(
            Icons.Outlined.PlayArrow,
            "Working",
            MaterialTheme.colorScheme.primary,
        )
        CodeSession.Status.NEEDS_INPUT -> Triple(
            Icons.Outlined.Warning,
            "Needs input",
            MaterialTheme.colorScheme.error,
        )
        CodeSession.Status.READY_FOR_REVIEW -> Triple(
            Icons.Outlined.CheckCircle,
            "Ready",
            Palette.Success,
        )
        CodeSession.Status.COMPLETED -> Triple(
            Icons.Outlined.CheckCircle,
            "Completed",
            MaterialTheme.colorScheme.onSurfaceVariant,
        )
        CodeSession.Status.ARCHIVED -> Triple(
            Icons.Outlined.Archive,
            "Archived",
            MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    Surface(
        color = tint.copy(alpha = 0.15f),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(50),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(12.dp))
            Spacer(Modifier.size(4.dp))
            Text(label, color = tint, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold)
        }
    }
}

private fun formatRelativeTime(epochMillis: Long): String {
    val now = System.currentTimeMillis()
    val diff = now - epochMillis
    return when {
        diff < 60_000L -> "just now"
        diff < 3_600_000L -> "${diff / 60_000L} min ago"
        diff < 86_400_000L -> "${diff / 3_600_000L} h ago"
        diff < 7 * 86_400_000L -> "${diff / 86_400_000L} d ago"
        else -> DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(epochMillis))
    }
}
