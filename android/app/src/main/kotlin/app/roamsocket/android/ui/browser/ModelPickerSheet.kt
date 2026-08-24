package app.roamsocket.android.ui.browser

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.core.providers.AIModel
import app.roamsocket.core.providers.ModelCatalog
import app.roamsocket.core.providers.ProviderId

/**
 * Compact model picker for the browser's top-bar pill. Shows the user's
 * configured provider's catalog (no live network fetch — the browser
 * runs on the chat's already-cached model list to keep the AI flow
 * snappy). If nothing is configured, the "Add a model" CTA jumps to
 * Settings.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelPickerSheet(
    currentModel: AIModel?,
    onSelect: (AIModel) -> Unit,
    onAddModel: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    val provider = currentModel?.provider ?: ProviderId.Anthropic
    val models = remember(provider) { ModelCatalog.defaultsFor(provider) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.background,
        dragHandle = null,
    ) {
        Column(modifier = Modifier.fillMaxSize().padding(horizontal = 14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    "Browser AI model",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                TextButton(onClick = onAddModel) { Text("Add a model", color = MaterialTheme.colorScheme.primary) }
            }
            Text(
                "${provider.displayName} · ${models.size} model${if (models.size == 1) "" else "s"}",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 4.dp),
            )
            LazyColumn(modifier = Modifier.fillMaxSize().padding(vertical = 4.dp)) {
                items(models, key = { it.id }) { model ->
                    val isSelected = currentModel?.id == model.id
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                onSelect(model)
                            }
                            .padding(vertical = 8.dp, horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                model.displayName,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Medium,
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                model.id,
                                fontSize = 11.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        if (isSelected) {
                            Icon(
                                imageVector = Icons.Filled.Check,
                                contentDescription = "Selected",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}
