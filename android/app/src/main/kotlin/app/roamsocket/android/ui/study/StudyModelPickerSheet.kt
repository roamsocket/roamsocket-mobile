package app.roamsocket.android.ui.study

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.providers.AIModel

/**
 * Bottom sheet for picking a vision-capable model for the study scan.
 * Ports the picker from iOS `StudyScanView` / `StudyModelPickerSheet`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StudyModelPickerSheet(
    models: List<AIModel>,
    selected: AIModel?,
    onSelect: (AIModel) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Palette.Surface,
        dragHandle = {
            Box(
                modifier = Modifier.padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    modifier = Modifier
                        .width(36.dp)
                        .height(5.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(Palette.SurfaceElevated),
                )
            }
        },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = 24.dp),
        ) {
            Text(
                text = "Study model",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                color = Palette.TextPrimary,
                modifier = Modifier.padding(start = 24.dp, top = 4.dp, bottom = 16.dp),
            )

            if (models.isEmpty()) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(24.dp),
                ) {
                    Text(
                        text = "No vision-capable models available.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = Palette.TextSecondary,
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Add an API key for OpenAI, Anthropic, OpenRouter, or xAI in Settings.",
                        style = MaterialTheme.typography.bodySmall,
                        color = Palette.TextTertiary,
                    )
                }
            } else {
                models.forEachIndexed { index, model ->
                    if (index > 0) {
                        HorizontalDivider(
                            color = Palette.Divider.copy(alpha = 0.5f),
                            modifier = Modifier.padding(horizontal = 24.dp),
                        )
                    }
                    ModelRow(
                        model = model,
                        isSelected = model.id == selected?.id,
                        onClick = { onSelect(model) },
                    )
                }
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
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 24.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = AIModel.prettifiedDisplayName(model.modelID),
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                color = Palette.TextPrimary,
            )
            Text(
                text = model.provider.displayName,
                style = MaterialTheme.typography.bodySmall,
                color = Palette.TextSecondary,
            )
        }
        if (isSelected) {
            Icon(
                imageVector = Icons.Outlined.Check,
                contentDescription = "Selected",
                tint = Palette.Accent,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}
