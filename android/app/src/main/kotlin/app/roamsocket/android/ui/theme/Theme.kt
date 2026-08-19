package app.roamsocket.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val DarkScheme = darkColorScheme(
    primary = Palette.Accent,
    onPrimary = Palette.OnAccent,
    primaryContainer = Palette.AccentPressed,
    onPrimaryContainer = Palette.OnAccent,
    background = Palette.Background,
    onBackground = Palette.TextPrimary,
    surface = Palette.Surface,
    onSurface = Palette.TextPrimary,
    surfaceVariant = Palette.SurfaceElevated,
    onSurfaceVariant = Palette.TextSecondary,
    outline = Palette.Divider,
    error = Palette.Danger,
    onError = Palette.OnAccent,
)

private val LightScheme = lightColorScheme(
    primary = Palette.Accent,
    onPrimary = Palette.OnAccent,
    primaryContainer = Palette.Accent,
    onPrimaryContainer = Palette.OnAccent,
    background = Palette.BackgroundLight,
    onBackground = Palette.TextPrimaryLight,
    surface = Palette.SurfaceLight,
    onSurface = Palette.TextPrimaryLight,
    surfaceVariant = Palette.SurfaceElevatedLight,
    onSurfaceVariant = Palette.TextSecondaryLight,
    outline = Palette.Divider,
    error = Palette.Danger,
    onError = Palette.OnAccent,
)

/**
 * App-wide Material 3 theme. We force the dark scheme by default (the
 * product is dark-first like the iOS app and Electron shell); a future
 * setting can opt into `MaterialTheme.colorScheme` for system-driven mode.
 */
@Composable
fun RoamSocketTheme(
    @Suppress("UNUSED_PARAMETER") darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = DarkScheme,
        typography = RoamSocketTypography,
        content = content,
    )
}
