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
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.roamsocket.android.BuildConfig
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.launch

/**
 * Settings tab — rendered as a modal bottom sheet, matching the iOS
 * `AppSettingsView` (X close button, "Settings" title, info icon at the
 * top; scrollable cards of grouped settings below).
 *
 * When the user lands here from the chat "Add a model" pill (or the
 * picker sheet) with no usable model, the [initialFocus] = `.providers`
 * opens the Provider API keys sub-sheet automatically, so they can
 * paste a key without an extra tap.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onDismiss: () -> Unit,
    initialFocus: SettingsFocus = SettingsFocus.None,
    viewModel: SettingsViewModel = viewModel(factory = SettingsViewModel.Factory),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var showProviderApiKeys by remember { mutableStateOf(false) }
    var showAbout by remember { mutableStateOf(false) }
    var showGitHubDialog by remember { mutableStateOf(false) }
    var showApiKeyDialogFor by remember { mutableStateOf<ProviderId?>(null) }

    // Auto-open the Provider API keys sub-sheet the first time the user
    // navigates here with `initialFocus = .providers` (i.e. from the
    // "Add a model" pill). Matches the iOS `SettingsFocus` behavior.
    var autoOpened by remember { mutableStateOf(false) }
    if (initialFocus == SettingsFocus.Providers && !autoOpened) {
        autoOpened = true
        showProviderApiKeys = true
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.background,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            SettingsHeader(
                onClose = {
                    scope.launch {
                        sheetState.hide()
                        onDismiss()
                    }
                },
                onInfo = { showAbout = true },
            )
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                item { AccountCard(state, showGitHubDialog = { showGitHubDialog = true }, showProviderApiKeys = { showProviderApiKeys = true }) }
                item { ChatCard() }
                item { EffortCard() }
                item { CodingCard() }
                item { SettingsBackupCard() }
                item { MarketplaceCard() }
                item { SkillsCard() }
                item { ConnectorsCard() }
                item { MemoryCard() }
            }
        }
    }

    if (showProviderApiKeys) {
        ProviderApiKeysSheet(
            providers = state.providers,
            onEdit = { provider ->
                // Dismiss the sub-sheet and pop the per-provider dialog
                // (a modal-on-modal stack gets weird on Android, so the
                // dialog hosts at the parent level).
                showProviderApiKeys = false
                showApiKeyDialogFor = provider
            },
            onAddCustomProvider = { /* TODO: route to custom provider sheet */ },
            onRefresh = { viewModel.refresh() },
            onDismiss = { showProviderApiKeys = false },
        )
    }

    showApiKeyDialogFor?.let { provider ->
        ApiKeyDialog(
            provider = provider,
            onDismiss = { showApiKeyDialogFor = null },
            onSave = { key ->
                viewModel.setApiKey(provider, key)
                showApiKeyDialogFor = null
            },
        )
    }

    if (showGitHubDialog) {
        GitHubPatDialog(
            onDismiss = { showGitHubDialog = false },
            onSave = { pat ->
                viewModel.setGitHubPat(pat)
                showGitHubDialog = false
            },
        )
    }

    if (showAbout) {
        AboutDialog(
            onDismiss = { showAbout = false },
            onOpenWebsite = {
                runCatching {
                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse("https://roamsocket.app"))
                    )
                }
            },
        )
    }
}

/** Optional entry focus. `.providers` jumps straight into the API-key sheet. */
enum class SettingsFocus { None, Providers }

// MARK: - Header

@Composable
private fun SettingsHeader(onClose: () -> Unit, onInfo: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(
            onClick = onClose,
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
                text = "Settings",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
        IconButton(
            onClick = onInfo,
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant),
        ) {
            Icon(
                imageVector = Icons.Outlined.Info,
                contentDescription = "About",
                tint = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

// MARK: - Card + Row primitives

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
            .padding(start = 56.dp)
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
    )
}

@Composable
private fun SettingsLinkRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    iconTint: Color,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = iconTint,
                modifier = Modifier.size(16.dp),
            )
        }
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = 12.dp),
        ) {
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
    }
}

@Composable
private fun PlaceholderRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    trailing: String? = null,
    showChevron: Boolean = false,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { /* placeholder */ }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp),
            )
        }
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = 12.dp),
        ) {
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
        if (trailing != null) {
            Text(
                text = trailing,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(end = 8.dp),
            )
        }
        if (showChevron) {
            Icon(
                imageVector = Icons.Outlined.RadioButtonUnchecked,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

// MARK: - Section cards

@Composable
private fun AccountCard(
    state: SettingsUiState,
    showGitHubDialog: () -> Unit,
    showProviderApiKeys: () -> Unit,
) {
    SettingsCard(title = "Account") {
        SettingsLinkRow(
            icon = Icons.Outlined.Link,
            iconTint = if (state.hasGitHubPat) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurfaceVariant,
            title = "GitHub Personal Access Token",
            subtitle = if (state.hasGitHubPat) "Token saved" else "Not set",
            onClick = showGitHubDialog,
        )
        Divider12()
        SettingsLinkRow(
            icon = Icons.Outlined.Key,
            iconTint = MaterialTheme.colorScheme.onSurface,
            title = "Provider API keys",
            subtitle = providerKeysSubtitle(state),
            onClick = showProviderApiKeys,
        )
    }
}

@Composable
private fun ChatCard() {
    SettingsCard(title = "Chat") {
        PlaceholderRow(
            icon = Icons.Outlined.Code,
            title = "Always expand thinking",
            subtitle = "Show full reasoning under the summary row.",
            trailing = "Coming soon",
        )
        Divider12()
        PlaceholderRow(
            icon = Icons.Outlined.Key,
            title = "Voice chat",
            subtitle = "Free neural voices — no key required.",
            trailing = "Free neural",
            showChevron = true,
        )
    }
}

@Composable
private fun EffortCard() {
    SettingsCard(title = "Effort") {
        PlaceholderRow(
            icon = Icons.Outlined.Key,
            title = "Effort",
            subtitle = "Low / Medium / High reasoning effort.",
            trailing = "High",
            showChevron = true,
        )
    }
}

@Composable
private fun CodingCard() {
    SettingsCard(title = "Coding") {
        PlaceholderRow(
            icon = Icons.Outlined.Link,
            title = "Desktop server",
            subtitle = "Manage in the Code tab.",
            trailing = "Manage in Code",
            showChevron = true,
        )
        Divider12()
        PlaceholderRow(
            icon = Icons.Outlined.Code,
            title = "Branch prefix",
            subtitle = "roamsocket",
        )
    }
}

@Composable
private fun SettingsBackupCard() {
    SettingsCard(title = "Settings backup") {
        PlaceholderRow(
            icon = Icons.Outlined.Link,
            title = "Sync to GitHub",
            subtitle = "Push settings to a private anyprov-code-settings repo.",
            trailing = "Sync",
            showChevron = true,
        )
        Divider12()
        PlaceholderRow(
            icon = Icons.Outlined.Link,
            title = "Restore from GitHub",
            subtitle = "Pull settings from a private anyprov-code-settings repo.",
            trailing = "Restore",
            showChevron = true,
        )
    }
}

@Composable
private fun MarketplaceCard() {
    SettingsCard(title = "Marketplace") {
        PlaceholderRow(
            icon = Icons.Outlined.Key,
            title = "Connectors, skills, plugins",
            subtitle = "Official catalog + your GitHub marketplace repos.",
            showChevron = true,
        )
    }
}

@Composable
private fun SkillsCard() {
    SettingsCard(title = "Skills") {
        PlaceholderRow(
            icon = Icons.Outlined.Key,
            title = "Manage skills",
            subtitle = "Pulled from the desktop agent on connect.",
            showChevron = true,
        )
    }
}

@Composable
private fun ConnectorsCard() {
    SettingsCard(title = "Connectors") {
        PlaceholderRow(
            icon = Icons.Outlined.Key,
            title = "Manage connectors",
            subtitle = "MCP servers (Model Context Protocol).",
            showChevron = true,
        )
    }
}

@Composable
private fun MemoryCard() {
    SettingsCard(title = "Memory") {
        PlaceholderRow(
            icon = Icons.Outlined.Key,
            title = "Manage memory",
            subtitle = "Long-term facts the agent remembers across chats.",
            showChevron = true,
        )
    }
}

// MARK: - Dialogs

@Composable
private fun ApiKeyDialog(
    provider: ProviderId,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var value by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("${provider.displayName} API key") },
        text = {
            OutlinedTextField(
                value = value,
                onValueChange = { value = it },
                label = { Text("API key") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    capitalization = KeyboardCapitalization.None,
                    imeAction = ImeAction.Done,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onSave(value.trim()) },
                enabled = value.trim().isNotEmpty(),
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun GitHubPatDialog(
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var value by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("GitHub Personal Access Token") },
        text = {
            Column {
                Text(
                    text = "Create a fine-grained PAT at github.com/settings/tokens with at least `repo` scope.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
                OutlinedTextField(
                    value = value,
                    onValueChange = { value = it },
                    label = { Text("ghp_…") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Password,
                        capitalization = KeyboardCapitalization.None,
                        imeAction = ImeAction.Done,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSave(value.trim()) },
                enabled = value.trim().isNotEmpty(),
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun AboutDialog(onDismiss: () -> Unit, onOpenWebsite: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("RoamSocket") },
        text = {
            Column {
                Text("Open-source native iOS and Android client for the RoamSocket desktop coding agent.")
                Text(
                    text = "v${BuildConfig.VERSION_NAME} · build ${BuildConfig.VERSION_CODE}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK") } },
        dismissButton = { TextButton(onClick = onOpenWebsite) { Text("roamsocket.app") } },
    )
}

// MARK: - Helpers

private fun providerKeysSubtitle(state: SettingsUiState): String {
    val setCount = state.providers.count { it.hasApiKey }
    return when {
        state.providers.isEmpty() -> "Loading…"
        setCount == 0 -> "No keys set"
        setCount == state.providers.size -> "All $setCount providers set"
        else -> "$setCount of ${state.providers.size} providers set"
    }
}

// Reuse the CheckCircle icon import for type safety — discard the unused
// warning by referencing the constant.
@Suppress("unused")
private val _checkCircleAnchor = Icons.Outlined.CheckCircle
@Suppress("unused")
private val _deleteAnchor = Icons.Outlined.Delete
