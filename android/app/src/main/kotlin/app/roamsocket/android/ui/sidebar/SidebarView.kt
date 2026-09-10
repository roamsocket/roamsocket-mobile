package app.roamsocket.android.ui.sidebar

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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.School
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.R
import app.roamsocket.android.ui.LocalAppContainer
import app.roamsocket.android.ui.theme.Palette
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.launch

/**
 * The left-edge navigation drawer. Mirrors iOS `SidebarView` 1:1 in
 * structure: header (title + study toggle), nav list (Chats / Vision /
 * Projects / Artifacts / Code / Browser, with Study mode swapping in
 * Classes / Scan questions / Decks), Recents list, optional download bar,
 * and a bottom bar with the user avatar (Settings) + New chat action.
 *
 * The component is pure — selection state and chat history are passed in.
 * The root view decides how to react to [onSelect].
 */
@Composable
fun SidebarView(
    history: ChatHistoryStore,
    onSelect: (SidebarDestination) -> Unit,
    onNewChat: () -> Unit,
    onShowSettings: () -> Unit,
    onOpenChat: (String) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val container = LocalAppContainer.current
    val studyMode by container.userSettings.studyModeEnabled.collectAsState(initial = false)
    val scope = rememberCoroutineScope()

    Surface(
        modifier = modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background,
    ) {
        // Single LazyColumn so the whole drawer scrolls together (header,
        // nav, recents, download bar, bottom bar). Previously a Column
        // with Spacer(weight=1f) pinned the bottom bar and the Recents
        // list was capped at 6 rows — long chat histories pushed the
        // "New chat" button off-screen. Now everything scrolls; long
        // Recents lists are no longer truncated.
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp)
                .padding(top = 8.dp, bottom = 8.dp),
            contentPadding = PaddingValues(vertical = 0.dp),
        ) {
            item(key = "header") {
                Header(
                    studyMode = studyMode,
                    onToggleStudy = {
                        scope.launch { container.userSettings.setStudyModeEnabled(!studyMode) }
                    },
                )
                // Tighter gap to the nav list — the 16dp spacer left a dead
                // band under the title on phones; 8dp keeps the rhythm
                // from iOS without crowding the first row.
                Spacer(modifier = Modifier.height(8.dp))
            }

            // Nav rows as their own items so the LazyColumn diff doesn't
            // churn the header when nav state toggles.
            navListItems(studyMode = studyMode, onSelect = onSelect)

            item(key = "recents-header") {
                Text(
                    text = stringResource(R.string.sidebar_recents),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelLarge,
                    // Tightened from (20, 8) — the 20dp top padding left a
                    // visible gap between the last nav row and "Recents"
                    // that made the section feel like a separate screen.
                    // 12dp top keeps the same hierarchy without the dead
                    // band.
                    modifier = Modifier.padding(top = 12.dp, bottom = 6.dp),
                )
            }
            val recents = history.activeRecents
            if (recents.isEmpty()) {
                item(key = "recents-empty") {
                    Text(
                        text = stringResource(R.string.sidebar_recents_empty),
                        color = Palette.TextTertiary,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
                    )
                }
            } else {
                items(recents, key = { it.id }) { item ->
                    RecentRow(item = item, onClick = { onOpenChat(item.id) })
                }
            }

            item(key = "bottom-bar") {
                BottomBar(
                    onShowSettings = onShowSettings,
                    onNewChat = onNewChat,
                )
            }
        }
    }
}

@Composable
private fun Header(studyMode: Boolean, onToggleStudy: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = stringResource(R.string.sidebar_title),
            color = MaterialTheme.colorScheme.onSurface,
            fontSize = 28.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(modifier = Modifier.weight(1f))
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .clickable(role = Role.Switch, onClick = onToggleStudy),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Outlined.School,
                contentDescription = if (studyMode) stringResource(R.string.sidebar_exit_study) else stringResource(R.string.sidebar_enter_study),
                tint = if (studyMode) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

/**
 * Emit each nav row as its own LazyColumn `item` so the column diffs
 * cleanly when study mode toggles. Returning a `LazyListScope` receiver
 * keeps the call site inside the parent `LazyColumn { ... }` block.
 */
private fun androidx.compose.foundation.lazy.LazyListScope.navListItems(
    studyMode: Boolean,
    onSelect: (SidebarDestination) -> Unit,
) {
    if (studyMode) {
        item(key = "nav.classes") {
            SidebarRow(
                icon = SidebarDestination.Classes.icon(),
                title = "Classes",
                onClick = { onSelect(SidebarDestination.Classes) },
            )
        }
        item(key = "nav.scan") {
            SidebarRow(
                icon = SidebarDestination.ScanQuestions.icon(),
                title = "Scan questions",
                onClick = { onSelect(SidebarDestination.ScanQuestions) },
            )
        }
        item(key = "nav.decks") {
            SidebarRow(
                icon = SidebarDestination.Study.icon(),
                title = "Decks",
                onClick = { onSelect(SidebarDestination.Study) },
            )
        }
        item(key = "nav.artifacts-study") {
            SidebarRow(
                icon = SidebarDestination.Artifacts.icon(),
                title = "Artifacts",
                onClick = { onSelect(SidebarDestination.Artifacts) },
            )
        }
    } else {
        item(key = "nav.chats") {
            SidebarRow(
                icon = SidebarDestination.Chats.icon(),
                title = "Chats",
                onClick = { onSelect(SidebarDestination.Chats) },
            )
        }
        item(key = "nav.vision") {
            SidebarRow(
                icon = SidebarDestination.Vision.icon(),
                title = "Vision",
                onClick = { onSelect(SidebarDestination.Vision) },
            )
        }
        item(key = "nav.projects") {
            SidebarRow(
                icon = SidebarDestination.Projects.icon(),
                title = "Projects",
                onClick = { onSelect(SidebarDestination.Projects) },
            )
        }
        item(key = "nav.artifacts") {
            SidebarRow(
                icon = SidebarDestination.Artifacts.icon(),
                title = "Artifacts",
                onClick = { onSelect(SidebarDestination.Artifacts) },
            )
        }
        item(key = "nav.code") {
            SidebarRow(
                icon = SidebarDestination.Code.icon(),
                title = "Code",
                onClick = { onSelect(SidebarDestination.Code) },
            )
        }
    }
    // Browser sits in both modes — same as iOS.
    item(key = "nav.browser") {
        SidebarRow(
            icon = SidebarDestination.Browser.icon(),
            title = "Browser",
            onClick = { onSelect(SidebarDestination.Browser) },
        )
    }
}

@Composable
private fun BottomBar(
    onShowSettings: () -> Unit,
    onNewChat: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            // Slightly tightened from (12, 4) — when the Recents list
            // grows the bottom bar should still feel anchored, but the
            // 12dp top was duplicating the gap below the last recent.
            .padding(top = 8.dp, bottom = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // Avatar / settings entry — initials on the iOS equivalent.
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .clickable(role = Role.Button, onClick = onShowSettings),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = "JS",
                color = MaterialTheme.colorScheme.onSurface,
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
            )
        }
        Spacer(modifier = Modifier.weight(1f))
        // New chat — primary action, accent fill, dark ink for contrast.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(MaterialTheme.colorScheme.primary)
                .clickable(role = Role.Button, onClick = onNewChat)
                .padding(horizontal = 16.dp, vertical = 11.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Add,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onPrimary,
                modifier = Modifier.size(15.dp),
            )
            Text(
                text = stringResource(R.string.sidebar_new_chat),
                color = MaterialTheme.colorScheme.onPrimary,
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}
