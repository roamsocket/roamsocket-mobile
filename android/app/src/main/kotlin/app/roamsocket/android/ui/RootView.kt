package app.roamsocket.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import app.roamsocket.android.R
import app.roamsocket.android.ui.chat.ChatScreen
import app.roamsocket.android.ui.code.CodeScreen

/**
 * Top-level shell mirroring the iOS `RootView` (sidebar + tab bar) but
 * using Android's bottom NavigationBar since Android has no
 * NavigationSplitView idiomatic in Compose Material 3 yet. Real navigation
 * will be wired up alongside the Chat feature port in the next PR.
 */
@Composable
fun RootView() {
    val tabs = listOf(
        TabSpec.Tab(R.string.tab_chat, Icons.Outlined.ChatBubbleOutline),
        TabSpec.Tab(R.string.tab_code, Icons.Outlined.Code),
        TabSpec.Tab(R.string.tab_skills, Icons.Outlined.Tune),
        TabSpec.Tab(R.string.tab_settings, Icons.Outlined.Settings),
    )

    var current by rememberSaveable { mutableStateOf(0) }

    Scaffold(
        bottomBar = {
            NavigationBar {
                tabs.forEachIndexed { index, tab ->
                    NavigationBarItem(
                        selected = current == index,
                        onClick = { current = index },
                        icon = { Icon(tab.icon, contentDescription = null) },
                        label = { Text(stringResource(tab.labelRes)) },
                    )
                }
            }
        },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when (current) {
                0 -> ChatScreen()
                1 -> CodeScreen()
                else -> PlaceholderTab(label = stringResource(tabs[current].labelRes))
            }
        }
    }
}

@Composable
private fun PlaceholderTab(label: String) {
    Box(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "$label — port coming in a later PR.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private sealed interface TabSpec {
    data class Tab(val labelRes: Int, val icon: ImageVector) : TabSpec
}
