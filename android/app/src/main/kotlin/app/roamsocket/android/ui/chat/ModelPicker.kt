package app.roamsocket.android.ui.chat

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ProviderId

/**
 * Provider + model picker that opens from the chat top bar. Lets the user
 * flip between built-in providers (Anthropic, OpenAI, …) and pick a
 * default model for each one.
 *
 * When the upstream `/v1/models` fetch returns nothing (or has not yet
 * completed), the picker title switches to an "Add a model" CTA that opens
 * the API key dialog — so the user never sees a stale "Provider · model"
 * chip that won't actually work. Once models are pulled the title
 * reverts to the normal provider/model chip.
 */
@Composable
fun ModelPicker(
    currentProvider: ProviderId,
    currentModel: String,
    models: List<AIModel>,
    /**
     * Result of the live `/v1/models` fetch for the current provider.
     * `null` = still loading (or never attempted); `[]` = upstream returned
     * nothing (likely a 401); non-empty = real, usable model list.
     */
    liveModels: List<AIModel>?,
    onSelectProvider: (ProviderId) -> Unit,
    onSelectModel: (String) -> Unit,
    onAddModel: () -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    var pendingProvider by remember { mutableStateOf(currentProvider) }

    // Show the "Add a model" pill when:
    //   1. The provider requires an API key (no point showing it for Metal),
    //      AND
    //   2. There's no live model list yet (still loading or upstream empty).
    // The user can still get to the dropdown via the menu icon in the toolbar
    // — this just makes the *title* honest about what'll actually work.
    val showAddModelCta =
        currentProvider.requiresApiKey && (liveModels == null || liveModels.isEmpty())

    Box {
        if (showAddModelCta) {
            TextButton(onClick = onAddModel) {
                Text("Add a model", color = MaterialTheme.colorScheme.primary)
            }
        } else {
            TextButton(onClick = { open = true; pendingProvider = currentProvider }) {
                Text("${currentProvider.displayName} · $currentModel")
            }
        }
        DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
        ) {
            Text(
                text = "Provider",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
            )
            ProviderId.BUILT_IN.filter { it is ProviderId.LocalMetal == false }.forEach { id ->
                DropdownMenuItem(
                    text = { Text(id.displayName) },
                    onClick = {
                        pendingProvider = id
                        onSelectProvider(id)
                    },
                )
            }
            HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))
            Text(
                text = "Model",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
            )
            val modelsForPending = models.filter { it.provider == pendingProvider }
            if (modelsForPending.isEmpty()) {
                Text(
                    text = "No models yet for $pendingProvider. Use the key icon to add an API key, then this list will refresh.",
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            } else {
                modelsForPending.forEach { model ->
                    DropdownMenuItem(
                        text = { Text(model.displayName) },
                        onClick = {
                            onSelectModel(model.modelID)
                            open = false
                        },
                    )
                }
            }
        }
    }
}

/** Modal for entering the API key for the current provider. */
@Composable
fun ApiKeyDialog(
    provider: ProviderId,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var value by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("${provider.displayName} API key") },
        text = {
            Box {
                LazyColumn(modifier = Modifier.heightIn(max = 240.dp).fillMaxWidth()) {
                    item {
                        Text(
                            text = "Stored encrypted in EncryptedSharedPreferences. Not synced.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(bottom = 8.dp),
                        )
                        OutlinedTextField(
                            value = value,
                            onValueChange = { value = it },
                            label = { Text("API key") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSave(value.trim()) },
                enabled = value.trim().isNotEmpty(),
            ) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}
