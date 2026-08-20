/*
 * HTTP pairing payloads (POST /pair). The 6-character code is shown in the
 * desktop server console; on success the response carries a bearer token
 * the app uses on every subsequent WebSocket frame.
 */
package app.roamsocket.core.protocol

import kotlinx.serialization.Serializable

@Serializable
public data class PairRequest(
    val code: String,
    val deviceName: String,
) {
    public companion object {
        public const val DEFAULT_DEVICE_NAME: String = "Android device"
    }
}

@Serializable
public data class PairResponse(
    val token: String,
    val serverName: String,
    val serverVersion: String,
    /** Public HTTPS base URL when a tunnel is already up at pair time. */
    val publicUrl: String? = null,
)
