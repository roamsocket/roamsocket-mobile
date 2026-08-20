package app.roamsocket.android.ui.chat

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ProviderId

/**
 * Capsule-shaped button rendered in the chat input bar that opens the
 * model picker sheet. Mirrors the iOS `ModelSelectorPill`:
 *  - shows the current model display name + chevron when a model is selected
 *  - shows an accent-tinted "Add a model" CTA when no usable model is set
 *    (caller supplies [onAddModel] to route the tap to provider settings)
 *
 * The pill is intentionally small and left-aligned so the surrounding
 * text field + send button keep their existing layout.
 */
@Composable
fun ModelPickerPill(
    modelDisplayName: String,
    hasUsableModel: Boolean,
    onPick: () -> Unit,
    onAddModel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        color = if (hasUsableModel) {
            MaterialTheme.colorScheme.surfaceContainerHigh
        } else {
            MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
        },
        shape = RoundedCornerShape(50),
        modifier = modifier
            .clip(RoundedCornerShape(50))
            .clickable { if (hasUsableModel) onPick() else onAddModel() },
    ) {
        if (hasUsableModel) {
            Row(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = modelDisplayName.ifBlank { "Select model" },
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Icon(
                    imageVector = Icons.Outlined.ExpandMore,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(16.dp),
                )
            }
        } else {
            Row(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(
                    imageVector = Icons.Outlined.ExpandMore,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    text = "Add a model",
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.primary,
                    maxLines = 1,
                )
            }
        }
    }
}

/**
 * "Select model" bottom sheet. Mirrors the iOS `ModelPickerSheet` in
 * spirit: a two-section list (Provider, then Model) where the model list
 * is filtered by the selected provider. Tapping a model selects it and
 * dismisses the sheet.
 *
 * The provider list intentionally hides `LocalMetal` (iOS-only on-device
 * provider) and excludes iOS-only ergonomics like Metal load controls.
 *
 * @param currentProvider the provider the view-model currently has
 * @param currentModel the model id the view-model currently has
 * @param models all known models for the catalog (per-provider, used to
 *   populate the model list for the active provider)
 * @param onSelectProvider invoked when the user changes provider
 * @param onSelectModel invoked when the user picks a model
 * @param onDismiss invoked when the sheet is closed without a pick
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelPickerSheet(
    currentProvider: ProviderId,
    currentModel: String,
    models: List<AIModel>,
    onSelectProvider: (ProviderId) -> Unit,
    onSelectModel: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    // Local override for the provider shown in the sheet so the user can
    // scroll the provider list without immediately firing the chat's
    // selection. The actual selection only commits when they tap a model.
    var pendingProvider by remember(currentProvider) { mutableStateOf(currentProvider) }
    val pendingModels = remember(pendingProvider, models) {
        models.filter { it.provider == pendingProvider }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 640.dp)
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            Text(
                text = "Select model",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp),
            )

            SectionLabel("Provider")
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 220.dp),
                contentPadding = PaddingValues(vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                val providers = ProviderId.BUILT_IN
                    .filter { it !is ProviderId.LocalMetal }
                items(providers, key = { it.rawValue }) { id ->
                    ProviderRow(
                        provider = id,
                        isSelected = pendingProvider == id,
                        onClick = {
                            pendingProvider = id
                            onSelectProvider(id)
                        },
                    )
                }
            }

            Spacer(Modifier.height(8.dp))
            SectionLabel("Model")
            if (pendingModels.isEmpty()) {
                Text(
                    text = "No defaults for ${pendingProvider.displayName} yet. Add an API key in Settings, or extend the catalog.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 12.dp),
                )
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 320.dp),
                    contentPadding = PaddingValues(vertical = 4.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    items(pendingModels, key = { it.modelID }) { model ->
                        ModelRow(
                            model = model,
                            isSelected = pendingProvider == currentProvider && model.modelID == currentModel,
                            onClick = {
                                onSelectProvider(pendingProvider)
                                onSelectModel(model.modelID)
                                onDismiss()
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
    )
}

@Composable
private fun ProviderRow(
    provider: ProviderId,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val bg = if (isSelected) {
        MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
    } else {
        MaterialTheme.colorScheme.surface
    }
    Surface(
        color = bg,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ProviderAvatar(provider = provider)
            Spacer(Modifier.size(12.dp))
            Text(
                text = provider.displayName,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
            )
            if (isSelected) {
                Icon(
                    imageVector = Icons.Outlined.Check,
                    contentDescription = "Selected",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@Composable
private fun ModelRow(
    model: AIModel,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val bg = if (isSelected) {
        MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
    } else {
        MaterialTheme.colorScheme.surface
    }
    Surface(
        color = bg,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = model.displayName,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                model.organization?.takeIf { it.isNotBlank() }?.let { org ->
                    Text(
                        text = org,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (isSelected) {
                Icon(
                    imageVector = Icons.Outlined.Check,
                    contentDescription = "Selected",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

/**
 * Tiny avatar circle for a provider row. Uses the first letter of the
 * display name to give each provider a stable visual identity without
 * shipping a full icon set.
 */
@Composable
private fun ProviderAvatar(provider: ProviderId) {
    Box(
        modifier = Modifier
            .size(28.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = provider.displayName.firstOrNull()?.uppercase() ?: "?",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.primary,
        )
    }
}
