package app.roamsocket.android.ui.session

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.protocol.EnvironmentConfig

/**
 * Centered status strip for an active coding session: environment name +
 * Local / Tunnel path. Tapping the connection chip surfaces a
 * preference picker (Smart / Always local / Always tunnel).
 *
 * Mirrors the iOS `EnvironmentConnectionPill`
 * (`ios/.../DesignSystem/EnvironmentConnectionPill.swift`).
 */
@Composable
fun EnvironmentConnectionPill(
    environment: EnvironmentConfig? = null,
    connectionPath: ConnectionPath = ConnectionPath.Offline,
    onPickPath: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        EnvChip(environment = environment)
        ConnectionChip(path = connectionPath, onClick = onPickPath)
    }
}

@Composable
private fun EnvChip(environment: EnvironmentConfig?) {
    val hasEnv = environment != null
    val name = environment?.name?.trim().orEmpty().ifEmpty { "No environment" }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(Palette.SurfaceElevated)
            .padding(horizontal = 10.dp, vertical = 6.dp),
    ) {
        Icon(
            imageVector = Icons.Outlined.Cloud,
            contentDescription = null,
            tint = if (hasEnv) Palette.TextPrimary else Palette.TextTertiary,
            modifier = Modifier.size(12.dp),
        )
        Text(
            text = name,
            color = if (hasEnv) Palette.TextPrimary else Palette.TextTertiary,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
    }
}

@Composable
private fun ConnectionChip(path: ConnectionPath, onClick: (() -> Unit)?) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(Palette.SurfaceElevated)
            .let { m ->
                if (onClick != null) m.clickable { onClick() } else m
            }
            .padding(horizontal = 10.dp, vertical = 6.dp),
    ) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(path.statusColor),
        )
        Icon(
            imageVector = path.icon,
            contentDescription = null,
            tint = Palette.TextPrimary,
            modifier = Modifier.size(12.dp),
        )
        Text(
            text = path.label,
            color = Palette.TextPrimary,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
        Icon(
            imageVector = Icons.Outlined.ExpandMore,
            contentDescription = "Change connection mode",
            tint = Palette.TextTertiary,
            modifier = Modifier.size(12.dp),
        )
    }
}

/** Mirrors iOS `AppState.ServerConnectionPath`. */
enum class ConnectionPath(val label: String, val statusColor: Color) {
    Offline("Not paired", Palette.TextTertiary),
    Local("Local", Palette.Success),
    Tunnel("Tunnel", Palette.Accent);

    val icon: androidx.compose.ui.graphics.vector.ImageVector
        get() = when (this) {
            Offline -> Icons.Outlined.Lock
            Local -> Icons.Outlined.Wifi
            Tunnel -> Icons.Outlined.Lock
        }
}
