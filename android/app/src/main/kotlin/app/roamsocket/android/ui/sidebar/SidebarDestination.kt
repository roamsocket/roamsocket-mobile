package app.roamsocket.android.ui.sidebar

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Brush
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Top-level destination the sidebar can navigate to. Mirrors the iOS
 * `SidebarDestination` (see `ios/App/Sources/Features/Sidebar/SidebarView.swift`)
 * so the two apps show the same drawer in spirit. A destination may either
 * be a top-level tab (chat, code, …) or a sub-screen (a specific chat id,
 * a project detail) that the root view swaps in.
 */
sealed class SidebarDestination {
    // Main navigation
    data object Chats : SidebarDestination()
    data object Vision : SidebarDestination()
    data object Projects : SidebarDestination()
    data object Artifacts : SidebarDestination()
    data object Code : SidebarDestination()
    data object Browser : SidebarDestination()
    data object Settings : SidebarDestination()
    data object Models : SidebarDestination()
    // Skills + MCP, matching the iOS Skills / Connectors tabs.
    data object Skills : SidebarDestination()
    data object Connectors : SidebarDestination()

    // Study mode only
    data object Classes : SidebarDestination()
    data object ScanQuestions : SidebarDestination()
    data object Study : SidebarDestination()

    // Item targets
    data class Chat(val id: String) : SidebarDestination()
    data class Project(val id: String) : SidebarDestination()
}

/** Material icon for a destination — keeps `SidebarView` declarative. */
fun SidebarDestination.icon(): ImageVector = when (this) {
    SidebarDestination.Chats -> Icons.Outlined.ChatBubbleOutline
    SidebarDestination.Vision -> Icons.Outlined.Visibility
    SidebarDestination.Projects -> Icons.Outlined.Folder
    SidebarDestination.Artifacts -> Icons.Outlined.Layers
    SidebarDestination.Code -> Icons.Outlined.Code
    SidebarDestination.Browser -> Icons.Outlined.Public
    SidebarDestination.Settings -> Icons.Outlined.Settings
    SidebarDestination.Models -> Icons.Outlined.Memory
    SidebarDestination.Skills -> Icons.Outlined.AutoAwesome
    SidebarDestination.Connectors -> Icons.Outlined.Dns
    SidebarDestination.Classes -> Icons.AutoMirrored.Outlined.MenuBook
    SidebarDestination.ScanQuestions -> Icons.Outlined.CameraAlt
    SidebarDestination.Study -> Icons.Outlined.Brush
    is SidebarDestination.Chat -> Icons.Outlined.ChatBubbleOutline
    is SidebarDestination.Project -> Icons.Outlined.Folder
}
