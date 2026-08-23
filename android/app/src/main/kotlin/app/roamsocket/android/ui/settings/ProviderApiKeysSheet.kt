package app.roamsocket.android.ui.settings

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.OpenInNew
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.launch

/**
 * "Provider API keys" sub-sheet opened from the main Settings sheet.
 * Mirrors the iOS `ProviderKeysView`:
 *
 * - Header with X close, "Provider API keys" title, "Done" right button.
 * - Subtitle: "Tap Edit to paste a key. The arrow button opens that
 *   provider's API key page in your browser." (the iOS copy says
 *   "Safari", we generalize it for Android.)
 * - Per-provider row: name on the left, status (bullets for set,
 *   "Not set" text) in the middle, "Edit" + external-link arrow on
 *   the right.
 * - "Add custom provider" CTA + "Refresh models" button.
 * - Footer: "Keys are stored encrypted in EncryptedSharedPreferences."
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProviderApiKeysSheet(
    providers: List<ProviderEntry>,
    onEdit: (ProviderId) -> Unit,
    onAddCustomProvider: () -> Unit,
    onRefresh: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var isRefreshing by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.background,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Header: X close, title, Done button.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(
                    onClick = {
                        scope.launch {
                            sheetState.hide()
                            onDismiss()
                        }
                    },
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Close,
                        contentDescription = "Close",
                        tint = MaterialTheme.colorScheme.onSurface,
                    )
                }
                Box(
                    modifier = Modifier.weight(1f),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "Provider API keys",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
                TextButton(
                    onClick = {
                        scope.launch {
                            sheetState.hide()
                            onDismiss()
                        }
                    },
                ) { Text("Done") }
            }

            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                item {
                    Text(
                        text = "Tap Edit to paste a key. The arrow button opens that provider's API key page in your browser.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 4.dp, bottom = 4.dp),
                    )
                }
                item { ChatCodingProvidersCard(providers, onEdit = onEdit) }
                item { VoiceModelsCard(providers, onEdit = onEdit) }
                item { CustomProvidersCard(isRefreshing, onAdd = onAddCustomProvider, onRefresh = {
                    isRefreshing = true
                    onRefresh()
                    scope.launch {
                        kotlinx.coroutines.delay(800)
                        isRefreshing = false
                    }
                }) }
                item {
                    Text(
                        text = "Keys are stored encrypted in EncryptedSharedPreferences.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 4.dp, top = 4.dp, bottom = 16.dp),
                    )
                }
            }
        }
    }
}

// MARK: - Section cards

@Composable
private fun ChatCodingProvidersCard(
    providers: List<ProviderEntry>,
    onEdit: (ProviderId) -> Unit,
) {
    SettingsCard(title = "Chat & coding providers") {
        providers.forEachIndexed { index, entry ->
            if (index > 0) Divider12()
            ProviderRow(
                entry = entry,
                onEdit = { onEdit(entry.provider) },
            )
        }
    }
}

@Composable
private fun VoiceModelsCard(
    providers: List<ProviderEntry>,
    onEdit: (ProviderId) -> Unit,
) {
    SettingsCard(title = "Voice models") {
        VoiceRow(
            title = "OpenAI TTS",
            subtitle = "Uses your OpenAI chat key above (not set yet).",
            isSet = providers.firstOrNull { it.provider == ProviderId.OpenAI }?.hasApiKey == true,
            onEdit = { onEdit(ProviderId.OpenAI) },
        )
        Divider12()
        VoiceRow(
            title = "ElevenLabs",
            subtitle = "Natural neural voices. Free tier ~ 10k characters/month.",
            isSet = false,
            trailingNote = "Not set",
        )
    }
}

@Composable
private fun CustomProvidersCard(
    isRefreshing: Boolean,
    onAdd: () -> Unit,
    onRefresh: () -> Unit,
) {
    SettingsCard(title = "Custom providers") {
        AddCustomProviderRow(onClick = onAdd)
        Divider12()
        RefreshModelsRow(isRefreshing = isRefreshing, onClick = onRefresh)
    }
}

// MARK: - Rows

@Composable
private fun ProviderRow(entry: ProviderEntry, onEdit: () -> Unit) {
    val context = LocalContext.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onEdit)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = entry.provider.displayName,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = if (entry.hasApiKey) "••••••" else "Not set",
            style = MaterialTheme.typography.bodyMedium,
            color = if (entry.hasApiKey) MaterialTheme.colorScheme.onSurface
                else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(end = 8.dp),
        )
        TextButton(
            onClick = onEdit,
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
        ) { Text("Edit") }
        IconButton(
            onClick = {
                runCatching {
                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(entry.provider.keyHelpUrl))
                    )
                }
            },
            modifier = Modifier.size(32.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.OpenInNew,
                contentDescription = "Open ${entry.provider.displayName} API key page",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun VoiceRow(
    title: String,
    subtitle: String,
    isSet: Boolean,
    trailingNote: String? = null,
    onEdit: (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (onEdit != null) it.clickable(onClick = onEdit) else it }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        val right = when {
            trailingNote != null -> trailingNote
            isSet -> "Edit"
            else -> "Edit"
        }
        Text(
            text = right,
            style = MaterialTheme.typography.bodyMedium,
            color = if (isSet) MaterialTheme.colorScheme.onSurfaceVariant
                else MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(end = 8.dp),
        )
        if (isSet) {
            Icon(
                imageVector = Icons.Outlined.OpenInNew,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(16.dp),
            )
        } else {
            Icon(
                imageVector = Icons.Outlined.OpenInNew,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun AddCustomProviderRow(onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Outlined.Add,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.size(16.dp),
            )
        }
        Text(
            text = "Add custom provider",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.primary,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 14.dp),
        )
    }
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 0.dp)) {
        Text(
            text = "Add Ollama, LiteLLM, OpenRouter proxies, or any OpenAI-compatible / Anthropic-compatible host. Pick the endpoint type, set the base URL (include /v1), and store this provider's own API key — do not put it under OpenAI.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(bottom = 14.dp, start = 42.dp),
        )
    }
}

@Composable
private fun RefreshModelsRow(isRefreshing: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = !isRefreshing, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = if (isRefreshing) "Refreshing models…" else "Refresh models",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.primary,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f),
        )
    }
}

// MARK: - Shared primitives (duplicated minimally to keep this file standalone)

@Composable
private fun SettingsCard(title: String, content: @Composable () -> Unit) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = title.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 4.dp, bottom = 6.dp),
        )
        Surface(
            color = MaterialTheme.colorScheme.surface,
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(modifier = Modifier.padding(vertical = 4.dp)) {
                content()
            }
        }
    }
}

@Composable
private fun Divider12() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .padding(start = 16.dp)
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
    )
}


/** Per-provider help URL used by the "open in browser" arrow icon. */
private val ProviderId.keyHelpUrl: String
    get() = when (this) {
        ProviderId.Anthropic -> "https://console.anthropic.com/settings/keys"
        ProviderId.OpenAI -> "https://platform.openai.com/api-keys"
        ProviderId.Google -> "https://aistudio.google.com/apikey"
        ProviderId.Groq -> "https://console.groq.com/keys"
        ProviderId.OpenRouter -> "https://openrouter.ai/settings/keys"
        ProviderId.XAI -> "https://console.x.ai/"
        ProviderId.Mistral -> "https://console.mistral.ai/api-keys/"
        ProviderId.MiniMax -> "https://platform.MiniMax.io/user-center/billing/balance-and-API-key"
        ProviderId.LocalMetal -> "https://developer.apple.com/metal/"
        is ProviderId.Custom -> "https://openrouter.ai/"
    }
