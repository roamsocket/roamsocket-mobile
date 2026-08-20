package app.roamsocket.android.ui

import androidx.compose.runtime.compositionLocalOf
import app.roamsocket.android.AppContainer

/**
 * CompositionLocal carrying the application-wide DI graph. Provided by
 * [MainActivity] so composables (especially the `SidebarView` and the
 * per-feature `ViewModel.Factory` builders) can reach the same singleton
 * `chatHistoryRepository`, `secretStore`, etc.
 */
val LocalAppContainer = compositionLocalOf<AppContainer> {
    error(
        "LocalAppContainer not provided. Wrap your composable hierarchy in " +
            "`CompositionLocalProvider(LocalAppContainer provides container) { ... }` " +
            "from MainActivity.",
    )
}
