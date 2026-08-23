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
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ModelCatalog
import app.roamsocket.core.providers.ProviderId

/**
 * Capsule-shaped button rendered in the chat input bar that opens the
 * model picker sheet. Mirrors the iOS `ModelSelectorPill`.
 *
 * - With a usable model: shows the model name + chevron and opens the
 *   picker sheet on tap.
 * - Without a usable model: shows an accent-tinted "Add a model" CTA
 *   and routes the tap to [onAddModel] (which takes the user to the
 *   Settings tab's Providers section so they can add a key).
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
 * "Select model" bottom sheet. Driven by [ModelCatalogViewModel] which
 * fetches the live provider catalog (skipping providers without API
 * keys). Each provider that returns at least one model is shown in the
 * top list; tapping it reveals that provider's models below.
 *
 * Per-provider errors (e.g. invalid key, 5xx) are surfaced in a
 * collapsed section at the bottom — same UX as iOS
 * `ModelPickerSheet.errorRow`. When the catalog comes back empty (no
 * configured providers, or every provider errored), the sheet shows an
 * "Add a model" CTA that takes the user to Settings.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelPickerSheet(
    currentProvider: ProviderId,
    currentModel: String,
    onSelectProvider: (ProviderId) -> Unit,
    onSelectModel: (String) -> Unit,
    onAddModel: () -> Unit,
    onDismiss: () -> Unit,
    viewModel: ModelCatalogViewModel = viewModel(factory = ModelCatalogViewModel.Factory),
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val state by viewModel.state.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) {
        // Re-fetch every time the sheet opens so a freshly added key
        // shows up immediately and we rely on live API data.
        viewModel.load(force = true)
    }

    // Split results into "has models" vs "error / empty".
    val usable = remember(state.results) {
        state.results.filter { it.models.isNotEmpty() }
    }
    val errors = remember(state.results) {
        state.results.filter { it.models.isEmpty() && it.error != null }
    }
    val pendingProvider: ProviderId? = remember(usable, currentProvider) {
        if (usable.any { it.provider == currentProvider }) currentProvider
        else usable.firstOrNull()?.provider
    }
    val pendingModels: List<AIModel> = remember(pendingProvider, usable) {
        usable.firstOrNull { it.provider == pendingProvider }?.models.orEmpty()
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 720.dp)
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            Text(
                text = "Select model",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp),
            )

            when {
                state.isLoading && usable.isEmpty() -> LoadingState()
                usable.isEmpty() -> EmptyConfiguredState(
                    errors = errors,
                    onAddModel = {
                        onAddModel()
                        onDismiss()
                    },
                )
                else -> {
                    SectionLabel("Provider")
                    LazyColumn(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 220.dp),
                        contentPadding = PaddingValues(vertical = 4.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        items(usable, key = { it.provider.rawValue }) { result ->
                            ProviderRow(
                                provider = result.provider,
                                isSelected = pendingProvider == result.provider,
                                onClick = { onSelectProvider(result.provider) },
                            )
                        }
                    }

                    Spacer(Modifier.height(8.dp))
                    SectionLabel("Model")
                    if (pendingModels.isEmpty()) {
                        Text(
                            text = "No models available for ${pendingProvider?.displayName ?: "this provider"}.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = 4.dp, vertical = 12.dp),
                        )
                    } else {
                        LazyColumn(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 360.dp),
                            contentPadding = PaddingValues(vertical = 4.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            items(pendingModels, key = { it.modelID }) { model ->
                                ModelRow(
                                    model = model,
                                    isSelected = pendingProvider == currentProvider && model.modelID == currentModel,
                                    onClick = {
                                        if (pendingProvider != null) {
                                            onSelectProvider(pendingProvider)
                                            onSelectModel(model.modelID)
                                            onDismiss()
                                        }
                                    },
                                )
                            }
                        }
                    }

                    if (errors.isNotEmpty()) {
                        Spacer(Modifier.height(8.dp))
                        SectionLabel("Errors")
                        LazyColumn(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 140.dp),
                            contentPadding = PaddingValues(vertical = 4.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            items(errors, key = { it.provider.rawValue }) { result ->
                                ErrorProviderRow(result)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LoadingState() {
    Box(modifier = Modifier.fillMaxWidth().padding(vertical = 40.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
    }
}

@Composable
private fun ErrorState(message: String) {
    // Kept for forward compatibility (e.g. a future per-sheet global
    // error banner). The current `when` branch in [ModelPickerSheet]
    // routes "no usable providers" through [EmptyConfiguredState]
    // instead, so this is unused for now.
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp, horizontal = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = message,
            color = MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Composable
private fun EmptyConfiguredState(
    errors: List<ModelCatalog.ProviderResult>,
    onAddModel: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp, horizontal = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = if (errors.isEmpty()) "No providers configured" else "Couldn't load any providers",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            text = if (errors.isEmpty()) {
                "Add an API key in Settings to choose a model."
            } else {
                "Every configured provider returned an error. Check your API keys in Settings."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        TextButton(onClick = onAddModel) {
            Text("Go to Settings", fontWeight = FontWeight.SemiBold)
        }
        if (errors.isNotEmpty()) {
            Spacer(Modifier.height(4.dp))
            LazyColumn(
                modifier = Modifier.fillMaxWidth().heightIn(max = 160.dp),
                contentPadding = PaddingValues(vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                items(errors, key = { it.provider.rawValue }) { result ->
                    ErrorProviderRow(result)
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
                    text = AIModel.prettifiedDisplayName(model.modelID),
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                )
                Text(
                    text = model.modelID,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                )
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

@Composable
private fun ErrorProviderRow(result: ModelCatalog.ProviderResult) {
    Surface(
        color = MaterialTheme.colorScheme.errorContainer,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
            Text(
                text = result.provider.displayName,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onErrorContainer,
            )
            Text(
                text = result.error.orEmpty(),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onErrorContainer,
            )
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
