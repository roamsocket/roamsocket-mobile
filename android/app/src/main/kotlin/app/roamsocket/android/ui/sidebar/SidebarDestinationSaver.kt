package app.roamsocket.android.ui.sidebar

import androidx.compose.runtime.saveable.Saver

/**
 * Maps a [SidebarDestination] to a stable string so it can survive
 * configuration changes via `rememberSaveable`. The format is
 * `kind:payload` — top-level destinations use an empty payload, item
 * destinations carry the id after the colon.
 */
val SidebarDestinationSaver: Saver<SidebarDestination, String> = Saver(
    save = { dest ->
        when (dest) {
            SidebarDestination.Chats -> "chats:"
            SidebarDestination.Vision -> "vision:"
            SidebarDestination.Projects -> "projects:"
            SidebarDestination.Artifacts -> "artifacts:"
            SidebarDestination.Code -> "code:"
            SidebarDestination.Browser -> "browser:"
            SidebarDestination.Settings -> "settings:"
            SidebarDestination.Models -> "models:"
            SidebarDestination.Classes -> "classes:"
            SidebarDestination.ScanQuestions -> "scanQuestions:"
            SidebarDestination.Study -> "study:"
            is SidebarDestination.Chat -> "chat:${dest.id}"
            is SidebarDestination.Project -> "project:${dest.id}"
        }
    },
    restore = { encoded ->
        val (kind, id) = encoded.split(":", limit = 2).let {
            it[0] to it.getOrNull(1).orEmpty()
        }
        when (kind) {
            "chats" -> SidebarDestination.Chats
            "vision" -> SidebarDestination.Vision
            "projects" -> SidebarDestination.Projects
            "artifacts" -> SidebarDestination.Artifacts
            "code" -> SidebarDestination.Code
            "browser" -> SidebarDestination.Browser
            "settings" -> SidebarDestination.Settings
            "models" -> SidebarDestination.Models
            "classes" -> SidebarDestination.Classes
            "scanQuestions" -> SidebarDestination.ScanQuestions
            "study" -> SidebarDestination.Study
            "chat" -> SidebarDestination.Chat(id)
            "project" -> SidebarDestination.Project(id)
            else -> SidebarDestination.Chats
        }
    },
)
