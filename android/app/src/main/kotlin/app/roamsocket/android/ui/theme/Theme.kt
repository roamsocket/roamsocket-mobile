package app.roamsocket.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import app.roamsocket.android.data.AppAppearance

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
 * App-wide Material 3 theme. The active scheme is selected from the
 * persisted [AppAppearance] preference:
 *
 * - [AppAppearance.System] follows the OS dark-mode flag (the default).
 * - [AppAppearance.Light] always renders the light scheme.
 * - [AppAppearance.Dark]  always renders the dark scheme.
 *
 * [MainActivity] reads `userSettings.appearance` as a Flow and
 * recomputes the `darkTheme` flag on every change so flipping the
 * Settings → Appearance card live-updates every screen.
 */
@Composable
fun RoamSocketTheme(
    appearance: AppAppearance = AppAppearance.System,
    @Suppress("UNUSED_PARAMETER") systemInDarkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val darkTheme = when (appearance) {
        AppAppearance.System -> systemInDarkTheme
        AppAppearance.Light -> false
        AppAppearance.Dark -> true
    }
    val scheme = if (darkTheme) DarkScheme else LightScheme
    MaterialTheme(
        colorScheme = scheme,
        typography = RoamSocketTypography,
        content = content,
    )
}
