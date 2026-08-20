package app.roamsocket.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import app.roamsocket.android.ui.chat.ChatScreen
import app.roamsocket.android.ui.code.CodeScreen
import app.roamsocket.android.ui.placeholder.PlaceholderScreen
import app.roamsocket.android.ui.sidebar.ChatHistoryStore
import app.roamsocket.android.ui.sidebar.SidebarDestination
import app.roamsocket.android.ui.sidebar.SidebarDestinationSaver
import app.roamsocket.android.ui.sidebar.SidebarView
import app.roamsocket.android.ui.sidebar.icon
import kotlinx.coroutines.launch

/**
 * `CompositionLocal` carrying a lambda that opens the left-edge sidebar
 * drawer. Every top-level screen installs the hamburger in its own
 * `TopAppBar` and calls this when the user taps the leading icon.
 */
val LocalOpenSidebar = compositionLocalOf<() -> Unit> { error("LocalOpenSidebar not provided") }

/**
 * Top-level shell. Mirrors the iOS `RootView` (sidebar drawer + content)
 * using a Compose `ModalNavigationDrawer` so the Android app presents the
 * same left-edge navigation as the iOS app.
 *
 * Each top-level destination has either a real screen (Chat, Code) or a
 * `PlaceholderScreen` while the Android port catches up.
 */
@Composable
fun RootView(history: ChatHistoryStore = remember { ChatHistoryStore() }) {
    var current by rememberSaveable(stateSaver = SidebarDestinationSaver) {
        mutableStateOf<SidebarDestination>(SidebarDestination.Chats)
    }
    val drawerState = rememberDrawerState(initialValue = DrawerValue.Closed)
    val scope = rememberCoroutineScope()

    fun navigate(to: SidebarDestination) {
        current = to
        scope.launch { drawerState.close() }
    }

    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            ModalDrawerSheet(
                modifier = Modifier.fillMaxWidth(0.82f),
                drawerContainerColor = MaterialTheme.colorScheme.background,
            ) {
                SidebarView(
                    history = history,
                    onSelect = ::navigate,
                    onNewChat = {
                        // Mirror the iOS "new chat" affordance: drop into a
                        // fresh chat by clearing the current selection.
                        current = SidebarDestination.Chats
                        scope.launch { drawerState.close() }
                    },
                    onShowSettings = {
                        navigate(SidebarDestination.Settings)
                    },
                )
            }
        },
        scrimColor = MaterialTheme.colorScheme.scrim.copy(alpha = 0.55f),
    ) {
        CompositionLocalProvider(
            LocalOpenSidebar provides { scope.launch { drawerState.open() } },
        ) {
            Box(modifier = Modifier.fillMaxSize()) {
                when (current) {
                    SidebarDestination.Chats, is SidebarDestination.Chat -> ChatScreen()
                    SidebarDestination.Code -> CodeScreen()
                    SidebarDestination.Settings -> PlaceholderScreen(
                        title = "Settings",
                        icon = Icons.Outlined.Settings,
                        onBack = { current = SidebarDestination.Chats },
                    )
                    else -> PlaceholderScreen(
                        title = labelFor(current),
                        icon = current.icon(),
                        onBack = { current = SidebarDestination.Chats },
                    )
                }
            }
        }
    }
}

private fun labelFor(dest: SidebarDestination): String = when (dest) {
    SidebarDestination.Chats -> "Chats"
    SidebarDestination.Vision -> "Vision"
    SidebarDestination.Projects -> "Projects"
    SidebarDestination.Artifacts -> "Artifacts"
    SidebarDestination.Code -> "Code"
    SidebarDestination.Browser -> "Browser"
    SidebarDestination.Settings -> "Settings"
    SidebarDestination.Models -> "Models"
    SidebarDestination.Classes -> "Classes"
    SidebarDestination.ScanQuestions -> "Scan questions"
    SidebarDestination.Study -> "Decks"
    is SidebarDestination.Chat -> "Chat"
    is SidebarDestination.Project -> "Project"
}
