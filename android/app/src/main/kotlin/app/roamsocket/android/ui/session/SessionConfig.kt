package app.roamsocket.android.ui.session

import app.roamsocket.core.providers.ProviderId
import app.roamsocket.core.protocol.Effort
import app.roamsocket.core.protocol.EnvironmentConfig
import app.roamsocket.core.protocol.PermissionMode
import app.roamsocket.core.protocol.RepoRef
import java.util.UUID

/**
 * Inputs the Code tab collects before opening a session. Mirrors
 * `ios/App/Sources/Features/Session/SessionConfig.swift`.
 */
data class SessionConfig(
    /** Stable id used by the Code home list to re-attach + persist the session. */
    val id: String = UUID.randomUUID().toString(),
    val repo: RepoRef,
    val model: SessionModelSelection,
    val permissionMode: PermissionMode = PermissionMode.ACCEPT_EDITS,
    val environment: EnvironmentConfig? = null,
    val skills: List<String> = emptyList(),
)

data class SessionModelSelection(
    val provider: ProviderId,
    val model: String,
    val effort: Effort = Effort.HIGH,
    val apiKey: String,
    val baseUrl: String? = null,
    val apiStyle: app.roamsocket.core.protocol.ApiStyle? = null,
)
