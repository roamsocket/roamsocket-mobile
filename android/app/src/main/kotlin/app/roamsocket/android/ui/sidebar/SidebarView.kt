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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.R
import app.roamsocket.android.ui.theme.Palette

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
    modifier: Modifier = Modifier,
) {
    var studyMode by rememberSaveable { mutableStateOf(false) }

    Surface(
        modifier = modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp)
                .padding(top = 8.dp, bottom = 8.dp),
        ) {
            Header(studyMode = studyMode, onToggleStudy = { studyMode = !studyMode })

            Spacer(modifier = Modifier.height(16.dp))

            NavList(
                studyMode = studyMode,
                onSelect = onSelect,
            )

            Recents(
                history = history,
                onSelectChat = { onSelect(SidebarDestination.Chat(it.id)) },
            )

            // Pin download + bottom bar to the edge so they don't shift
            // when the Recents list grows.
            Spacer(modifier = Modifier.weight(1f))
            BottomBar(
                onShowSettings = onShowSettings,
                onNewChat = onNewChat,
            )
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

@Composable
private fun NavList(
    studyMode: Boolean,
    onSelect: (SidebarDestination) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (studyMode) {
            SidebarRow(
                icon = SidebarDestination.Classes.icon(),
                title = "Classes",
                onClick = { onSelect(SidebarDestination.Classes) },
            )
            SidebarRow(
                icon = SidebarDestination.ScanQuestions.icon(),
                title = "Scan questions",
                onClick = { onSelect(SidebarDestination.ScanQuestions) },
            )
            SidebarRow(
                icon = SidebarDestination.Study.icon(),
                title = "Decks",
                onClick = { onSelect(SidebarDestination.Study) },
            )
            SidebarRow(
                icon = SidebarDestination.Artifacts.icon(),
                title = "Artifacts",
                onClick = { onSelect(SidebarDestination.Artifacts) },
            )
        } else {
            SidebarRow(
                icon = SidebarDestination.Chats.icon(),
                title = "Chats",
                onClick = { onSelect(SidebarDestination.Chats) },
            )
            SidebarRow(
                icon = SidebarDestination.Vision.icon(),
                title = "Vision",
                onClick = { onSelect(SidebarDestination.Vision) },
            )
            SidebarRow(
                icon = SidebarDestination.Projects.icon(),
                title = "Projects",
                onClick = { onSelect(SidebarDestination.Projects) },
            )
            SidebarRow(
                icon = SidebarDestination.Artifacts.icon(),
                title = "Artifacts",
                onClick = { onSelect(SidebarDestination.Artifacts) },
            )
            SidebarRow(
                icon = SidebarDestination.Code.icon(),
                title = "Code",
                onClick = { onSelect(SidebarDestination.Code) },
            )
        }
        // Browser sits in both modes — same as iOS.
        SidebarRow(
            icon = SidebarDestination.Browser.icon(),
            title = "Browser",
            onClick = { onSelect(SidebarDestination.Browser) },
        )
    }
}

@Composable
private fun Recents(
    history: ChatHistoryStore,
    onSelectChat: (ChatHistoryItem) -> Unit,
) {
    val items = history.activeRecents
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = stringResource(R.string.sidebar_recents),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier.padding(top = 20.dp, bottom = 8.dp),
        )
        if (items.isEmpty()) {
            Text(
                text = stringResource(R.string.sidebar_recents_empty),
                color = Palette.TextTertiary,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
            )
        } else {
            // Cap the list to 6 visible rows; the real list lives in the
            // bottom panel when the user opens Chats.
            val visible = items.take(6)
            LazyColumn(
                modifier = Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(vertical = 0.dp),
                verticalArrangement = Arrangement.spacedBy(0.dp),
            ) {
                items(visible, key = { it.id }) { item ->
                    RecentRow(item = item, onClick = { onSelectChat(item) })
                }
            }
        }
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
            .padding(top = 12.dp, bottom = 4.dp),
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
