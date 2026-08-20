package app.roamsocket.android.ui.markdown

/**
 * The Markwon-backed MarkdownText Composable is exercised end-to-end via
 * `assembleDebug` and the live Chat screen. Unit tests for the renderer
 * are not added here because Markwon requires a real Android `Context`,
 * which Robolectric can host but the value over a manual smoke test is
 * marginal for a "first PR" surface.
 */
internal class MarkdownTextSmokeTest
