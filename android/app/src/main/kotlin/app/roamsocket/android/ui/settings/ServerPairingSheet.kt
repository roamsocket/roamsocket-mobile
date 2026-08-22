package app.roamsocket.android.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.data.PairedServer
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.server.Endpoint
import app.roamsocket.core.server.ServerClient
import app.roamsocket.core.server.ServerClientException
import kotlinx.coroutines.launch

/**
 * Re-pair sheet shown when the saved pairing token is rejected.
 * Mirrors the iOS `ServerPairingView` + the re-pair trigger in
 * `SessionViewModel` (`needsRePair` flow).
 *
 * Flow:
 *  1. The user types the desktop address + 6-character code.
 *  2. We call `ServerClient.pair(...)` to exchange the code for a
 *     bearer token.
 *  3. On success we save via [onPaired] so the caller (Session VM
 *     or Settings) can reconnect.
 */
@Composable
fun ServerPairingSheet(
    initialHost: String = "http://localhost:4319",
    initialCode: String = "",
    title: String = "Pair with desktop",
    description: String = "Open the desktop server, then type the 6-character code shown there.",
    showCancel: Boolean = true,
    onDismiss: () -> Unit,
    onPaired: (PairedServer) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var host by remember { mutableStateOf(initialHost) }
    var code by remember { mutableStateOf(initialCode) }
    var status by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    val endpoint = remember(host) { Endpoint.fromHost(host) }
    val canPair = !busy && code.trim().length == 6 && endpoint != null

    Surface(
        color = MaterialTheme.colorScheme.background,
        modifier = Modifier
            .fillMaxSize()
            .imePadding()
            .navigationBarsPadding(),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.Surface)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                if (showCancel) {
                    TextButton(onClick = onDismiss) { Text("Cancel") }
                }
                Spacer(Modifier.weight(1f))
                Text(
                    text = title,
                    color = Palette.TextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.weight(1f))
                TextButton(
                    onClick = {
                        if (!canPair || endpoint == null) return@TextButton
                        busy = true
                        error = null
                        status = "Pairing…"
                        scope.launch {
                            try {
                                val deviceName = android.os.Build.MODEL ?: "Android"
                                val response = ServerClient().pair(
                                    endpoint = endpoint,
                                    code = code.trim(),
                                    deviceName = deviceName,
                                )
                                // The Android `PairResponse` doesn't echo the
                                // endpoint; we trust the host the user typed
                                // (it just worked) and pair from there.
                                val server = PairedServer(
                                    endpoint = endpoint.baseURL,
                                    token = response.token,
                                    serverName = response.serverName,
                                    serverVersion = response.serverVersion,
                                    publicUrl = response.publicUrl,
                                )
                                status = "Paired as ${server.serverName}."
                                onPaired(server)
                            } catch (e: ServerClientException.PairFailed) {
                                error = e.detail
                                status = null
                            } catch (e: Throwable) {
                                error = e.message ?: e.javaClass.simpleName
                                status = null
                            } finally {
                                busy = false
                            }
                        }
                    },
                    enabled = canPair,
                ) {
                    if (busy) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(14.dp),
                            strokeWidth = 1.5.dp,
                            color = MaterialTheme.colorScheme.onPrimary,
                        )
                    } else {
                        Text("Pair")
                    }
                }
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    text = description,
                    color = Palette.TextSecondary,
                    fontSize = 13.sp,
                )
                TextField(
                    value = host,
                    onValueChange = { host = it.trim() },
                    label = { Text("Server address") },
                    placeholder = { Text("192.168.1.10:4319") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.None,
                        keyboardType = KeyboardType.Uri,
                        imeAction = ImeAction.Next,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                TextField(
                    value = code,
                    onValueChange = { input ->
                        // Codes are alphanumeric uppercase; auto-upper.
                        code = input.uppercase().take(8)
                    },
                    label = { Text("Pairing code") },
                    placeholder = { Text("ABC123") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Characters,
                        keyboardType = KeyboardType.Ascii,
                        imeAction = ImeAction.Done,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                if (endpoint == null && host.isNotEmpty()) {
                    Text(
                        text = "That address doesn't look right — try `192.168.1.10:4319` or a full `http://host:port` URL.",
                        color = MaterialTheme.colorScheme.error,
                        fontSize = 12.sp,
                    )
                }
                status?.let { msg ->
                    Text(
                        text = msg,
                        color = Palette.Accent,
                        fontSize = 12.sp,
                    )
                }
                error?.let { err ->
                    Text(
                        text = err,
                        color = MaterialTheme.colorScheme.error,
                        fontSize = 12.sp,
                    )
                }
                Spacer(Modifier.size(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Outlined.QrCodeScanner,
                        contentDescription = null,
                        tint = Palette.TextTertiary,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.size(6.dp))
                    Text(
                        text = "QR scanning lives in the desktop app — pair with the desktop's 6-character code for now.",
                        color = Palette.TextTertiary,
                        fontSize = 12.sp,
                    )
                }
            }
        }
    }
}
