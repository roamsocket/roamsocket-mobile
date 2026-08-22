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
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.DarkMode
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.LightMode
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.MicNone
import androidx.compose.material.icons.outlined.PhoneIphone
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.RecordVoiceOver
import androidx.compose.material.icons.outlined.SettingsBrightness
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.WorkspacePremium
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.roamsocket.android.AppContainer
import app.roamsocket.android.BuildConfig
import app.roamsocket.android.data.AppAppearance
import app.roamsocket.android.data.EffortLevel
import app.roamsocket.android.data.VoiceProvider
import app.roamsocket.android.ui.LocalNavigateToCode
import app.roamsocket.android.ui.LocalNavigateToSidebar
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
    var showVoiceSettings by remember { mutableStateOf(false) }
    var showMemorySheet by remember { mutableStateOf(false) }
    var showMarketplaceSheet by remember { mutableStateOf(false) }
    var showSkillsSheet by remember { mutableStateOf(false) }
    var showConnectorsSheet by remember { mutableStateOf(false) }

    val closeSheet: () -> Unit = {
        scope.launch {
            sheetState.hide()
            onDismiss()
        }
    }

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
                onClose = closeSheet,
                onInfo = { showAbout = true },
            )
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                item { AccountCard(state, showGitHubDialog = { showGitHubDialog = true }, showProviderApiKeys = { showProviderApiKeys = true }) }
                item { AppearanceCard(state, onSetAppearance = viewModel::setAppearance) }
                item { ChatCard(state, onToggle = viewModel::setAlwaysExpandThinking, onOpenVoice = { showVoiceSettings = true }) }
                item { EffortCard(state, onSetEffort = viewModel::setEffort) }
                item { CodingCard(state, onSetBranchPrefix = viewModel::setBranchPrefix) }
                item { SettingsBackupCard(state, onPush = viewModel::pushSettings, onPull = viewModel::pullSettings) }
                item { MarketplaceCard { showMarketplaceSheet = true } }
                item { SkillsCard { showSkillsSheet = true } }
                item { ConnectorsCard { showConnectorsSheet = true } }
                item { MemoryCard { showMemorySheet = true } }
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

    if (showVoiceSettings) {
        VoiceSettingsSheet(
            state = state,
            onSetProvider = viewModel::setVoiceProvider,
            onSetOpenAIModel = viewModel::setVoiceOpenAIModel,
            onDismiss = { showVoiceSettings = false },
        )
    }

    if (showMemorySheet) {
        MemorySheet(onDismiss = { showMemorySheet = false })
    }

    if (showMarketplaceSheet) {
        MarketplaceSheet(onDismiss = { showMarketplaceSheet = false })
    }

    if (showSkillsSheet) {
        SkillsSheet(onDismiss = { showSkillsSheet = false })
    }

    if (showConnectorsSheet) {
        ConnectorsSheet(onDismiss = { showConnectorsSheet = false })
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

/** Tappable settings row with icon + title + subtitle + (optional)
 *  trailing text. Used for both link rows (tap navigates) and inline
 *  display rows (no tap target). */
@Composable
private fun SettingsLinkRow(
    icon: ImageVector,
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

/** Like [SettingsLinkRow] but with a fixed trailing label and a
 *  chevron — used for navigation rows whose destination has no value
 *  to display inline (e.g. Manage in Code). */
@Composable
private fun PlaceholderRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    trailing: String? = null,
    showChevron: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    val clickModifier = if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier
    Row(
        modifier = clickModifier
            .fillMaxWidth()
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

/** Inline settings row with a switch on the right (toggle on/off). */
@Composable
private fun ToggleRow(
    icon: ImageVector,
    iconTint: Color,
    title: String,
    subtitle: String,
    isOn: Boolean,
    onToggle: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onToggle(!isOn) }
            .padding(horizontal = 16.dp, vertical = 12.dp),
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
        Switch(
            checked = isOn,
            onCheckedChange = onToggle,
            colors = SwitchDefaults.colors(
                checkedThumbColor = MaterialTheme.colorScheme.background,
                checkedTrackColor = MaterialTheme.colorScheme.primary,
            ),
        )
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
private fun AppearanceCard(
    state: SettingsUiState,
    onSetAppearance: (AppAppearance) -> Unit,
) {
    SettingsCard(title = "Appearance") {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SegmentedOption(
                    label = "System",
                    icon = Icons.Outlined.SettingsBrightness,
                    selected = state.appearance == AppAppearance.System,
                    onClick = { onSetAppearance(AppAppearance.System) },
                    modifier = Modifier.weight(1f),
                )
                SegmentedOption(
                    label = "Light",
                    icon = Icons.Outlined.LightMode,
                    selected = state.appearance == AppAppearance.Light,
                    onClick = { onSetAppearance(AppAppearance.Light) },
                    modifier = Modifier.weight(1f),
                )
                SegmentedOption(
                    label = "Dark",
                    icon = Icons.Outlined.DarkMode,
                    selected = state.appearance == AppAppearance.Dark,
                    onClick = { onSetAppearance(AppAppearance.Dark) },
                    modifier = Modifier.weight(1f),
                )
            }
            Spacer(Modifier.size(8.dp))
            Text(
                text = "Theme follows the system setting by default.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ChatCard(
    state: SettingsUiState,
    onToggle: (Boolean) -> Unit,
    onOpenVoice: () -> Unit,
) {
    SettingsCard(title = "Chat") {
        ToggleRow(
            icon = Icons.Outlined.Psychology,
            iconTint = MaterialTheme.colorScheme.primary,
            title = "Always expand thinking",
            subtitle = "Show full reasoning under the summary row.",
            isOn = state.alwaysExpandThinking,
            onToggle = onToggle,
        )
        Divider12()
        PlaceholderRow(
            icon = Icons.Outlined.GraphicEq,
            title = "Voice chat",
            subtitle = voiceProviderSubtitle(state),
            trailing = state.voiceProvider.display,
            showChevron = true,
            onClick = onOpenVoice,
        )
    }
}

@Composable
private fun EffortCard(
    state: SettingsUiState,
    onSetEffort: (EffortLevel) -> Unit,
) {
    SettingsCard(title = "Effort") {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                EffortLevel.values().forEach { level ->
                    SegmentedOption(
                        label = level.display,
                        selected = state.effort == level,
                        onClick = { onSetEffort(level) },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
            Spacer(Modifier.size(8.dp))
            Text(
                text = state.effort.description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun CodingCard(
    state: SettingsUiState,
    onSetBranchPrefix: (String) -> Unit,
) {
    val navigateToCode = LocalNavigateToCode.current
    SettingsCard(title = "Coding") {
        PlaceholderRow(
            icon = Icons.Outlined.Terminal,
            title = "Desktop server",
            subtitle = "Manage in the Code tab.",
            trailing = "Manage in Code",
            showChevron = true,
            onClick = navigateToCode,
        )
        Divider12()
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(28.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Code,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp),
                    )
                }
                Spacer(Modifier.size(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Branch prefix",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "Each coding session gets its own branch: ${previewBranchExample(state.branchPrefix)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(Modifier.size(8.dp))
            OutlinedTextField(
                value = state.branchPrefix,
                onValueChange = onSetBranchPrefix,
                label = { Text("Prefix") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    imeAction = ImeAction.Done,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun SettingsBackupCard(
    state: SettingsUiState,
    onPush: () -> Unit,
    onPull: () -> Unit,
) {
    SettingsCard(title = "Settings backup") {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Text(
                text = if (state.hasGitHubPat) {
                    "We create a private roamsocket-mobile-settings repo in your account and push every setting (preferences, voice, model) there."
                } else {
                    "Add a GitHub PAT above, then sync to push settings to a private roamsocket-mobile-settings repo."
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.size(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledChipButton(
                    label = "Sync to GitHub",
                    icon = Icons.Outlined.Sync,
                    enabled = state.hasGitHubPat && !state.syncInFlight,
                    onClick = onPush,
                    modifier = Modifier.weight(1f),
                )
                OutlinedChipButton(
                    label = "Restore",
                    icon = Icons.Outlined.Sync,
                    enabled = state.hasGitHubPat && !state.syncInFlight,
                    onClick = onPull,
                    modifier = Modifier.weight(1f),
                )
            }
            if (state.syncInFlight) {
                Spacer(Modifier.size(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 2.dp,
                    )
                    Spacer(Modifier.size(8.dp))
                    Text(
                        text = "Talking to GitHub…",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            state.syncMessage?.let { msg ->
                Spacer(Modifier.size(6.dp))
                Text(
                    text = msg,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
            state.syncError?.let { err ->
                Spacer(Modifier.size(6.dp))
                Text(
                    text = err,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
            if (state.syncStatuses.isNotEmpty()) {
                Spacer(Modifier.size(6.dp))
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    state.syncStatuses.forEach { (kind, line) ->
                        Row(verticalAlignment = Alignment.Top) {
                            Text(
                                text = "$kind",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.width(96.dp),
                            )
                            Spacer(Modifier.size(6.dp))
                            Text(
                                text = line,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MarketplaceCard(onOpen: () -> Unit) {
    SettingsCard(title = "Marketplace") {
        PlaceholderRow(
            icon = Icons.Outlined.WorkspacePremium,
            title = "Connectors, skills, plugins",
            subtitle = "Official catalog + your GitHub marketplace repos.",
            showChevron = true,
            onClick = onOpen,
        )
    }
}

@Composable
private fun SkillsCard(onOpen: () -> Unit) {
    SettingsCard(title = "Skills") {
        PlaceholderRow(
            icon = Icons.Outlined.Psychology,
            title = "Manage skills",
            subtitle = "Pulled from the desktop agent on connect.",
            showChevron = true,
            onClick = onOpen,
        )
    }
}

@Composable
private fun ConnectorsCard(onOpen: () -> Unit) {
    SettingsCard(title = "Connectors") {
        PlaceholderRow(
            icon = Icons.Outlined.Bolt,
            title = "Manage connectors",
            subtitle = "MCP servers (Model Context Protocol).",
            showChevron = true,
            onClick = onOpen,
        )
    }
}

@Composable
private fun MemoryCard(onOpen: () -> Unit) {
    SettingsCard(title = "Memory") {
        PlaceholderRow(
            icon = Icons.Outlined.Memory,
            title = "Manage memory",
            subtitle = "Long-term facts the agent remembers across chats.",
            showChevron = true,
            onClick = onOpen,
        )
    }
}

// MARK: - Sub-screens

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceSettingsSheet(
    state: SettingsUiState,
    onSetProvider: (VoiceProvider) -> Unit,
    onSetOpenAIModel: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.fillMaxSize()) {
            SubSheetHeader(title = "Voice chat", onClose = onDismiss)
            LazyColumn(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                item {
                    SettingsCard(title = "Provider") {
                        Column(modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)) {
                            VoiceProvider.values().forEach { provider ->
                                VoiceProviderRow(
                                    provider = provider,
                                    selected = state.voiceProvider == provider,
                                    onClick = { onSetProvider(provider) },
                                )
                            }
                        }
                    }
                }
                if (state.voiceProvider == VoiceProvider.OpenAITTS) {
                    item {
                        SettingsCard(title = "OpenAI TTS") {
                            Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                                Text(
                                    text = "Model",
                                    style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.onSurface,
                                )
                                Spacer(Modifier.size(8.dp))
                                OPENAI_TTS_MODELS.forEach { model ->
                                    VoiceModelRow(
                                        modelId = model.id,
                                        displayName = model.display,
                                        description = model.description,
                                        selected = state.voiceOpenAIModel == model.id,
                                        onClick = { onSetOpenAIModel(model.id) },
                                    )
                                }
                                Spacer(Modifier.size(8.dp))
                                OutlinedTextField(
                                    value = state.voiceOpenAIModel,
                                    onValueChange = onSetOpenAIModel,
                                    label = { Text("Custom model id") },
                                    singleLine = true,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            }
                        }
                    }
                }
                if (state.voiceProvider == VoiceProvider.ElevenLabs) {
                    item {
                        SettingsCard(title = "ElevenLabs") {
                            Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                                Text(
                                    text = "Set the ElevenLabs API key in the Provider API keys sheet to enable voice chat with ElevenLabs voices.",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
                item {
                    SettingsCard(title = "Status") {
                        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                            Text(
                                text = voiceProviderSubtitle(state),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun VoiceProviderRow(
    provider: VoiceProvider,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Outlined.RecordVoiceOver,
            contentDescription = null,
            tint = if (selected) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.size(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = provider.display,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = voiceProviderDescription(provider),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (selected) {
            Icon(
                imageVector = Icons.Outlined.Check,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
            )
        }
    }
}

@Composable
private fun VoiceModelRow(
    modelId: String,
    displayName: String,
    description: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioDot(selected = selected)
        Spacer(Modifier.size(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = displayName,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            text = modelId,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private data class OpenAITtsModel(val id: String, val display: String, val description: String)

private val OPENAI_TTS_MODELS = listOf(
    OpenAITtsModel("tts-1", "Standard", "Lower latency, lower cost. Good for most replies."),
    OpenAITtsModel("tts-1-hd", "HD", "Higher quality, slower, more expensive."),
    OpenAITtsModel("gpt-4o-mini-tts", "GPT-4o mini TTS", "Newest model, supports natural-language voice steering."),
)

private fun voiceProviderDescription(provider: VoiceProvider): String = when (provider) {
    VoiceProvider.FreeNeural -> "Built-in neural voices — no key required."
    VoiceProvider.OpenAITTS -> "OpenAI's text-to-speech. Uses the OpenAI provider key."
    VoiceProvider.ElevenLabs -> "ElevenLabs voices. Requires a separate API key."
}

private fun voiceProviderSubtitle(state: SettingsUiState): String = when (state.voiceProvider) {
    VoiceProvider.FreeNeural -> "Free neural voices — no key required."
    VoiceProvider.OpenAITTS -> "OpenAI TTS · ${state.voiceOpenAIModel}"
    VoiceProvider.ElevenLabs -> "ElevenLabs · set key in Provider API keys"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MemorySheet(onDismiss: () -> Unit) {
    InfoSheet(
        title = "Manage memory",
        icon = Icons.Outlined.Memory,
        body = listOf(
            "Long-term facts the agent remembers across chats.",
            "On Android, memory entries live behind the desktop agent. " +
                "Pair with a desktop server, then ask it to remember things — " +
                "they'll surface in chat and stay until you remove them.",
        ),
        onDismiss = onDismiss,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MarketplaceSheet(onDismiss: () -> Unit) {
    InfoSheet(
        title = "Marketplace",
        icon = Icons.Outlined.WorkspacePremium,
        body = listOf(
            "Official catalog + your GitHub marketplace repos.",
            "Browse and install connector, skill, and plugin repos hosted on " +
                "GitHub. The catalog list is pulled from the desktop agent; " +
                "the mobile app is a read-only view until we wire purchases.",
        ),
        onDismiss = onDismiss,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SkillsSheet(onDismiss: () -> Unit) {
    InfoSheet(
        title = "Manage skills",
        icon = Icons.Outlined.Psychology,
        body = listOf(
            "Skills are reusable instructions the agent follows per task.",
            "The desktop agent maintains the canonical skill list. " +
                "When you pair a desktop, skills sync into the mobile " +
                "composer and you can toggle which ones are active per chat.",
        ),
        onDismiss = onDismiss,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConnectorsSheet(onDismiss: () -> Unit) {
    InfoSheet(
        title = "Manage connectors",
        icon = Icons.Outlined.Bolt,
        body = listOf(
            "Connectors let the agent call external services (Calendar, " +
                "Drive, GitHub, etc.) via MCP.",
            "Add or remove connectors on the desktop; the mobile app " +
                "shows the live list once a desktop is paired.",
        ),
        onDismiss = onDismiss,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InfoSheet(
    title: String,
    icon: ImageVector,
    body: List<String>,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.fillMaxSize()) {
            SubSheetHeader(title = title, onClose = onDismiss)
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 24.dp, vertical = 12.dp),
                horizontalAlignment = Alignment.Start,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(56.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(28.dp),
                    )
                }
                body.forEach { paragraph ->
                    Text(
                        text = paragraph,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }
    }
}

@Composable
private fun SubSheetHeader(title: String, onClose: () -> Unit) {
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
                text = title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
        Spacer(Modifier.size(40.dp))
    }
}

// MARK: - Generic sub-components

@Composable
private fun SegmentedOption(
    label: String,
    icon: ImageVector? = null,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val container = if (selected) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.surfaceVariant
    val onContainer = if (selected) MaterialTheme.colorScheme.onPrimary
        else MaterialTheme.colorScheme.onSurface
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(container)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (icon != null) {
            Icon(imageVector = icon, contentDescription = null, tint = onContainer, modifier = Modifier.size(16.dp))
            Spacer(Modifier.size(6.dp))
        }
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge,
            color = onContainer,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        )
    }
}

@Composable
private fun FilledChipButton(
    label: String,
    icon: ImageVector,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(
                if (enabled) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.primary.copy(alpha = 0.3f)
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (enabled) MaterialTheme.colorScheme.onPrimary
                else MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.6f),
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.size(6.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge,
            color = if (enabled) MaterialTheme.colorScheme.onPrimary
                else MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.6f),
        )
    }
}

@Composable
private fun OutlinedChipButton(
    label: String,
    icon: ImageVector,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = if (enabled) 1f else 0.4f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (enabled) MaterialTheme.colorScheme.onSurface
                else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f),
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.size(6.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge,
            color = if (enabled) MaterialTheme.colorScheme.onSurface
                else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f),
        )
    }
}

@Composable
private fun RadioDot(selected: Boolean) {
    val outer = if (selected) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
    val inner = if (selected) MaterialTheme.colorScheme.primary else Color.Transparent
    Box(
        modifier = Modifier
            .size(20.dp)
            .clip(CircleShape)
            .background(Color.Transparent),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(18.dp)
                .clip(CircleShape)
                .background(Color.Transparent)
                .padding(2.dp),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(18.dp)
                    .clip(CircleShape)
                    .background(Color.Transparent),
            )
            Box(
                modifier = Modifier
                    .size(18.dp)
                    .clip(CircleShape),
            ) {
                Box(
                    modifier = Modifier
                        .size(18.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.background),
                )
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(inner)
                        .padding(2.dp)
                        .align(Alignment.Center),
                )
            }
        }
        Box(
            modifier = Modifier
                .size(20.dp)
                .clip(CircleShape)
                .background(Color.Transparent),
        ) {
            Box(
                modifier = Modifier
                    .padding(2.dp)
                    .size(16.dp)
                    .clip(CircleShape)
                    .background(outer.copy(alpha = 0.15f)),
            )
        }
    }
}

private fun previewBranchExample(prefix: String): String {
    val safe = prefix.trim().ifBlank { "roamsocket" }
    return "$safe/your-task-a1b2c3d4"
}

private fun providerKeysSubtitle(state: SettingsUiState): String {
    val count = state.providers.count { it.hasApiKey }
    return when (count) {
        0 -> "Not set"
        1 -> "1 of ${state.providers.size} providers set"
        else -> "$count of ${state.providers.size} providers set"
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
private fun AboutDialog(
    onDismiss: () -> Unit,
    onOpenWebsite: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("RoamSocket") },
        text = {
            Column {
                Text(
                    text = "Build ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.size(8.dp))
                Text(
                    text = "Native iOS chat client with a desktop companion that runs the real coding agent.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
        },
        confirmButton = { TextButton(onClick = onOpenWebsite) { Text("roamsocket.app") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}

@Composable
fun providerKeysSubtitleForTest(state: SettingsUiState): String = providerKeysSubtitle(state)
