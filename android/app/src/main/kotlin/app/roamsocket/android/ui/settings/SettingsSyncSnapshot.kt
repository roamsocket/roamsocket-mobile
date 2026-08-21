package app.roamsocket.android.ui.settings

import app.roamsocket.android.data.AppAppearance
import app.roamsocket.android.data.EffortLevel
import app.roamsocket.android.data.ToolAccessLevel
import app.roamsocket.android.data.VoiceProvider
import app.roamsocket.core.providers.ProviderId
import kotlinx.serialization.Serializable

/**
 * JSON snapshot of every Android user setting that we sync to the
 * user's GitHub repo (default: `roamsocket-mobile-settings`,
 * auto-created on first push). Mirrors the iOS
 * `AppSettingsSnapshot` schema-version pattern so a future
 * cross-platform restore can downgrade gracefully.
 */
@Serializable
data class SettingsSyncSnapshot(
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val generatedAt: String = "",
    val alwaysExpandThinking: Boolean = false,
    val effort: String = EffortLevel.High.raw,
    val appearance: String = AppAppearance.System.raw,
    val branchPrefix: String = "roamsocket",
    val voiceProvider: String = VoiceProvider.FreeNeural.raw,
    val voiceOpenAIModel: String = "tts-1",
    val currentProvider: String = ProviderId.Anthropic.rawValue,
    val currentModel: String = "claude-3-5-sonnet-20241022",
    val researchEnabled: Boolean = false,
    val webSearchEnabled: Boolean = false,
    val locationEnabled: Boolean = false,
    val toolAccess: String = ToolAccessLevel.Auto.raw,
) {
    companion object {
        const val CURRENT_SCHEMA_VERSION: Int = 1
        const val FILE_PATH: String = "settings.json"
        const val REPO_NAME: String = "roamsocket-mobile-settings"
    }
}
