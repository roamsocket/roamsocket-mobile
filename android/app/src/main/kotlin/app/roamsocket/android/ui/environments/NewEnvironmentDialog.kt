package app.roamsocket.android.ui.environments

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.protocol.EnvironmentConfig
import app.roamsocket.core.protocol.NetworkAccess

/**
 * "New cloud environment" form. Collects the same four fields the iOS
 * [NewEnvironmentView] uses:
 *  - name
 *  - network access (None / Trusted / Limited / Custom)
 *  - allowed domains (only when Custom)
 *  - .env-format environment variables
 *
 * The composed [EnvironmentConfig] is delivered to [onCreate] exactly
 * once; the caller decides where to persist it.
 *
 * Mirrors iOS `NewEnvironmentView` in
 * `ios/App/Sources/Features/Environments/NewEnvironmentView.swift`.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun NewEnvironmentDialog(
    onDismiss: () -> Unit,
    onCreate: (EnvironmentConfig) -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var networkAccess by remember { mutableStateOf(NetworkAccess.TRUSTED) }
    var customDomains by remember { mutableStateOf("") }
    var envText by remember { mutableStateOf("") }
    var networkMenuOpen by remember { mutableStateOf(false) }

    val canSubmit = name.trim().isNotEmpty()
    val nameFocus = remember { FocusRequester() }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        nameFocus.requestFocus()
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.Background,
        title = {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "New cloud environment",
                    color = Palette.TextPrimary,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onDismiss) {
                    Icon(
                        imageVector = Icons.Outlined.Close,
                        contentDescription = "Close",
                        tint = Palette.TextPrimary,
                    )
                }
            }
        },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 540.dp)
                    .verticalScroll(rememberScrollState())
                    .imePadding(),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                LabeledField(label = "Name") {
                    BasicTextField(
                        value = name,
                        onValueChange = { name = it },
                        textStyle = TextStyle(
                            color = Palette.TextPrimary,
                            fontSize = 16.sp,
                        ),
                        singleLine = true,
                        cursorBrush = androidx.compose.ui.graphics.SolidColor(Palette.Accent),
                        modifier = Modifier
                            .fillMaxWidth()
                            .focusRequester(nameFocus),
                        decorationBox = { inner ->
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(Palette.Surface)
                                    .padding(horizontal = 16.dp, vertical = 14.dp),
                            ) {
                                if (name.isEmpty()) {
                                    Text(
                                        text = "Default",
                                        color = Palette.TextTertiary,
                                        fontSize = 16.sp,
                                    )
                                }
                                inner()
                            }
                        },
                    )
                }

                LabeledField(label = "Network access") {
                    Box {
                        NetworkAccessRow(
                            access = networkAccess,
                            onClick = { networkMenuOpen = true },
                        )
                        DropdownMenu(
                            expanded = networkMenuOpen,
                            onDismissRequest = { networkMenuOpen = false },
                            modifier = Modifier
                                .background(Palette.Surface)
                                .clip(RoundedCornerShape(12.dp)),
                        ) {
                            NetworkAccess.values().forEach { option ->
                                DropdownMenuItem(
                                    text = {
                                        Column {
                                            Text(
                                                text = option.displayName,
                                                color = Palette.TextPrimary,
                                                fontSize = 15.sp,
                                                fontWeight = FontWeight.SemiBold,
                                            )
                                            Text(
                                                text = option.subtitle,
                                                color = Palette.TextSecondary,
                                                fontSize = 12.sp,
                                            )
                                        }
                                    },
                                    onClick = {
                                        networkAccess = option
                                        networkMenuOpen = false
                                    },
                                )
                            }
                        }
                    }
                }

                if (networkAccess == NetworkAccess.CUSTOM) {
                    LabeledField(
                        label = "Allowed domains",
                        helper = "One host per line. Subdomains match automatically.",
                    ) {
                        MultiLineField(
                            value = customDomains,
                            onValueChange = { customDomains = it },
                            placeholder = "api.github.com\npypi.org",
                            monospace = true,
                            minHeight = 120.dp,
                        )
                    }
                }

                LabeledField(
                    label = "Environment variables",
                    helper = "In .env format.",
                ) {
                    MultiLineField(
                        value = envText,
                        onValueChange = { envText = it },
                        placeholder = "API_KEY=hunter2",
                        monospace = true,
                        minHeight = 160.dp,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    if (!canSubmit) return@TextButton
                    val domains = customDomains
                        .split('\n', ',')
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                    val env = EnvironmentConfig(
                        name = name.trim(),
                        networkAccess = networkAccess,
                        allowedDomains = if (networkAccess == NetworkAccess.CUSTOM) domains else emptyList(),
                        variables = parseEnvText(envText),
                    )
                    onCreate(env)
                },
                enabled = canSubmit,
            ) {
                Text(
                    text = "Create environment",
                    color = if (canSubmit) Palette.OnAccent else Palette.TextTertiary,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun LabeledField(
    label: String,
    helper: String? = null,
    content: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = label,
            color = Palette.TextSecondary,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
        )
        content()
        if (helper != null) {
            Text(
                text = helper,
                color = Palette.TextTertiary,
                fontSize = 12.sp,
            )
        }
    }
}

@Composable
private fun NetworkAccessRow(access: NetworkAccess, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Palette.Surface)
            .clickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = access.displayName,
            color = Palette.TextPrimary,
            fontSize = 16.sp,
            modifier = Modifier.weight(1f),
        )
        Icon(
            imageVector = Icons.Outlined.ExpandMore,
            contentDescription = null,
            tint = Palette.TextSecondary,
            modifier = Modifier.size(18.dp),
        )
    }
}

@Composable
private fun MultiLineField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    monospace: Boolean,
    minHeight: androidx.compose.ui.unit.Dp,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = minHeight)
            .clip(RoundedCornerShape(16.dp))
            .background(Palette.Surface)
            .padding(horizontal = 12.dp, vertical = 12.dp),
    ) {
        if (value.isEmpty()) {
            Text(
                text = placeholder,
                color = Palette.TextTertiary,
                fontSize = if (monospace) 14.sp else 16.sp,
                fontFamily = if (monospace) FontFamily.Monospace else null,
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
            )
        }
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            textStyle = TextStyle(
                color = Palette.TextPrimary,
                fontSize = if (monospace) 14.sp else 16.sp,
                fontFamily = if (monospace) FontFamily.Monospace else null,
            ),
            cursorBrush = androidx.compose.ui.graphics.SolidColor(Palette.Accent),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 4.dp, vertical = 4.dp),
        )
    }
}

/**
 * Minimal `.env` parser — supports `KEY=value` lines, ignores blanks
 * and `#` comments, strips optional surrounding quotes. Mirrors
 * `EnvironmentConfig.parseEnv` in
 * `ios/App/Sources/Features/Session/SessionConfig.swift`.
 */
internal fun parseEnvText(text: String): Map<String, String> {
    val out = LinkedHashMap<String, String>()
    for (line in text.split('\n')) {
        val stripped = line.trim()
        if (stripped.isEmpty() || stripped.startsWith("#")) continue
        val eq = stripped.indexOf('=')
        if (eq <= 0) continue
        val key = stripped.substring(0, eq).trim()
        if (key.isEmpty()) continue
        var value = stripped.substring(eq + 1).trim()
        if (value.length >= 2 &&
            ((value.startsWith("\"") && value.endsWith("\"")) ||
                (value.startsWith("'") && value.endsWith("'")))
        ) {
            value = value.substring(1, value.length - 1)
        }
        out[key] = value
    }
    return out
}
