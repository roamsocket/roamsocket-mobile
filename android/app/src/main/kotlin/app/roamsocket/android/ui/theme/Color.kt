package app.roamsocket.android.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Cool blue-grey palette shared with the iOS Theme and the Electron shell
 * (see `desktop-server/src/renderer/styles.css` `:root`). Do not introduce
 * a second palette or terracotta accents without an explicit product
 * decision — see AGENTS.md theme invariant.
 */
internal object Palette {
    // Base
    val Background = Color(0xFF0B0D10)
    val Surface = Color(0xFF14181D)
    val SurfaceElevated = Color(0xFF1B2026)
    val Divider = Color(0xFF2A3038)

    // Text
    val TextPrimary = Color(0xFFE6EAF0)
    val TextSecondary = Color(0xFFA4ADBA)
    val TextTertiary = Color(0xFF6C7682)

    // Accent
    val Accent = Color(0xFF6AA9FF)
    val AccentPressed = Color(0xFF4F8DEB)
    val OnAccent = Color(0xFF0B0D10)

    // Semantic
    val Success = Color(0xFF7AC8A3)
    val Warning = Color(0xFFE6B86A)
    val Danger = Color(0xFFE07485)
    val Info = Color(0xFF6AA9FF)

    // Light scheme (rare — Android system theme). Mirrors the iOS light
    // palette in case the device's system theme wins.
    val BackgroundLight = Color(0xFFFAFBFC)
    val SurfaceLight = Color(0xFFFFFFFF)
    val SurfaceElevatedLight = Color(0xFFF1F3F6)
    val TextPrimaryLight = Color(0xFF14181D)
    val TextSecondaryLight = Color(0xFF5A6470)
}
