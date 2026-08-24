package app.roamsocket.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import app.roamsocket.android.ui.browser.BrowserHomeView
import app.roamsocket.android.ui.chat.ChatScreen
import app.roamsocket.android.ui.code.CodeScreen
import app.roamsocket.android.ui.mcp.MCPScreen
import app.roamsocket.android.ui.placeholder.PlaceholderScreen
import app.roamsocket.android.ui.settings.SettingsFocus
import app.roamsocket.android.ui.settings.SettingsScreen
import app.roamsocket.android.ui.sidebar.SidebarDestination
import app.roamsocket.android.ui.sidebar.SidebarDestinationSaver
import app.roamsocket.android.ui.sidebar.SidebarView
import app.roamsocket.android.ui.sidebar.icon
import app.roamsocket.android.ui.sidebar.rememberChatHistoryStore
import app.roamsocket.android.ui.skills.SkillsScreen
import app.roamsocket.android.ui.vision.VisionScreen
import kotlinx.coroutines.launch

/**
 * `CompositionLocal` carrying a lambda that opens the left-edge sidebar
 * drawer. Every top-level screen installs the hamburger in its own
 * `TopAppBar` and calls this when the user taps the leading icon.
 */
val LocalOpenSidebar = compositionLocalOf<() -> Unit> { error("LocalOpenSidebar not provided") }

/**
 * `CompositionLocal` carrying a lambda that switches the top-level
 * destination to Settings. Used by the chat's "Add a model" pill (and
 * the picker's empty state) to take the user to the Providers section
 * of Settings when no API key is configured.
 */
val LocalNavigateToSettings = compositionLocalOf<() -> Unit> { error("LocalNavigateToSettings not provided") }

/**
 * `CompositionLocal` carrying a lambda that switches the top-level
 * destination to the Code tab. Used by the chat's "Add to Chat → Start
 * coding session" entry (port #12) to jump into the desktop agent
 * without making the chat composable aware of the navigation graph.
 */
val LocalNavigateToCode = compositionLocalOf<() -> Unit> { error("LocalNavigateToCode not provided") }

/**
 * `CompositionLocal` carrying a lambda that switches the top-level
 * destination to an arbitrary [SidebarDestination]. Used by the chat's
 * Add to Chat sheet (port #12) to route to Projects, Connectors, and
 * any future placeholder destinations.
 */
val LocalNavigateToSidebar = compositionLocalOf<(SidebarDestination) -> Unit> {
    error("LocalNavigateToSidebar not provided")
}

/**
 * `CompositionLocal` carrying the initial focus for the next Settings
 * presentation. The chat's "Add a model" pill sets this to
 * [SettingsFocus.Providers] before navigating, so the modal opens
 * straight into the API-key editor — matching the iOS flow.
 */
val LocalSettingsFocus = compositionLocalOf<SettingsFocus> { SettingsFocus.None }

/**
 * Top-level shell. Mirrors the iOS `RootView` (sidebar drawer + content)
 * using a Compose `ModalNavigationDrawer` so the Android app presents the
 * same left-edge navigation as the iOS app.
 *
 * Each top-level destination has either a real screen (Chat, Code) or a
 * `PlaceholderScreen` while the Android port catches up.
 *
 * The chat list and active chat id are owned here so the sidebar's
 * Recents list and the `ChatScreen` can stay in sync (PR 1: chat
 * history persistence).
 */
@Composable
fun RootView() {
    val chatHistory = rememberChatHistoryStore()
    var current by rememberSaveable(stateSaver = SidebarDestinationSaver) {
        mutableStateOf<SidebarDestination>(SidebarDestination.Chats)
    }
    // Stable id of the chat the user is currently looking at. Held here
    // so sidebar taps + new-chat both flow into the ChatScreen.
    var activeChatId by rememberSaveable { mutableStateOf<String?>(null) }
    // Initial focus for the next Settings presentation. The chat's
    // "Add a model" pill writes [SettingsFocus.Providers] here before
    // navigating so the modal opens straight into the API-key editor.
    var initialSettingsFocus by remember { mutableStateOf<SettingsFocus>(SettingsFocus.None) }
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
                    history = chatHistory,
                    onSelect = ::navigate,
                    onNewChat = {
                        // Mint a fresh chat in the repository and make it
                        // the active one. The ChatScreen will resume it
                        // once the first message lands (or just render an
                        // empty composer for the blank draft).
                        activeChatId = chatHistory.startNewChat()
                        current = SidebarDestination.Chats
                        scope.launch { drawerState.close() }
                    },
                    onOpenChat = { id ->
                        chatHistory.openChat(id)
                        activeChatId = id
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
            LocalNavigateToSettings provides { current = SidebarDestination.Settings },
            LocalNavigateToCode provides { current = SidebarDestination.Code },
            LocalNavigateToSidebar provides { dest -> navigate(dest) },
            LocalSettingsFocus provides initialSettingsFocus.also { initialSettingsFocus = SettingsFocus.None },
        ) {
            Box(modifier = Modifier.fillMaxSize()) {
                when (current) {
                    // Combined: chatId wire (from chat-history) +
                    // onNavigateToSettings (from repo picker).
                    SidebarDestination.Chats, is SidebarDestination.Chat -> ChatScreen(chatId = activeChatId)
                    SidebarDestination.Code -> CodeScreen(
                        onNavigateToSettings = { current = SidebarDestination.Settings },
                    )
                    SidebarDestination.Vision -> VisionScreen(
                        onClose = { current = SidebarDestination.Chats },
                    )
                    SidebarDestination.Browser -> {
                        // Browser holds its own store on the AppContainer so
                        // tabs/history/chat survive sidebar navigation, mirroring
                        // the iOS `AppState.browserStore` pattern.
                        BrowserHomeView(store = LocalAppContainer.current.browserStore)
                    }
                    SidebarDestination.Settings -> SettingsScreen(
                        onDismiss = { current = SidebarDestination.Chats },
                        initialFocus = LocalSettingsFocus.current,
                    )
                    SidebarDestination.Skills -> SkillsScreen(
                        onBack = { current = SidebarDestination.Chats },
                    )
                    SidebarDestination.Connectors -> MCPScreen(
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
    SidebarDestination.Skills -> "Skills"
    SidebarDestination.Connectors -> "Connectors"
    SidebarDestination.Classes -> "Classes"
    SidebarDestination.ScanQuestions -> "Scan questions"
    SidebarDestination.Study -> "Decks"
    is SidebarDestination.Chat -> "Chat"
    is SidebarDestination.Project -> "Project"
}
