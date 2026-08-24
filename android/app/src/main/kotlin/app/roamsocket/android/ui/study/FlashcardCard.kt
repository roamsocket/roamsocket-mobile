package app.roamsocket.android.ui.study

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.QuestionMark
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette

/**
 * One editable flashcard card: Question / Answer / Reasoning fields plus a
 * per-card Save button. Shared by the scan review flow and deck detail.
 *
 * Ports [StudyFlashcardCardView] from iOS `StudyFlashcardCardView.swift`.
 *
 * @param showSaveButton Hide the per-card Save button (deck detail auto-saves on edit).
 * @param onDelete Optional delete callback shown next to save button.
 */
@Composable
fun FlashcardCard(
    index: Int,
    question: String,
    answer: String,
    reasoning: String,
    saveState: StudyCardSaveState,
    showSaveButton: Boolean = true,
    onQuestionChange: (String) -> Unit = {},
    onAnswerChange: (String) -> Unit = {},
    onReasonChange: (String) -> Unit = {},
    onSave: () -> Unit = {},
    onDelete: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val isUnsaved = saveState == StudyCardSaveState.UNSAVED
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        color = Palette.Surface,
        border = BorderStroke(
            width = if (isUnsaved) 1.5.dp else 1.dp,
            color = if (isUnsaved) Palette.Accent.copy(alpha = 0.4f) else Palette.Divider.copy(alpha = 0.7f),
        ),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
        ) {
            // Header row: "Question N" + save/delete buttons
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "Question $index",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.TextPrimary,
                )
                Spacer(modifier = Modifier.weight(1f))
                if (showSaveButton) {
                    SaveButton(saveState = saveState, onClick = onSave)
                }
                if (onDelete != null) {
                    Spacer(modifier = Modifier.width(6.dp))
                    IconButton(
                        onClick = onDelete,
                        modifier = Modifier.size(30.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.CheckCircle,
                            contentDescription = "Delete question $index",
                            tint = Palette.TextSecondary,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(14.dp))

            FieldRow(
                label = "Question",
                icon = Icons.Outlined.QuestionMark,
                value = question,
                placeholder = "Type the question\u2026",
                onValueChange = onQuestionChange,
            )

            Spacer(modifier = Modifier.height(14.dp))

            FieldRow(
                label = "Answer",
                icon = Icons.Outlined.Check,
                value = answer,
                placeholder = "Type the answer\u2026",
                onValueChange = onAnswerChange,
            )

            Spacer(modifier = Modifier.height(14.dp))

            FieldRow(
                label = "Reason",
                icon = Icons.Outlined.Lightbulb,
                value = reasoning,
                placeholder = "Why is this correct?\u2026",
                onValueChange = onReasonChange,
            )
        }
    }
}

@Composable
private fun SaveButton(
    saveState: StudyCardSaveState,
    onClick: () -> Unit,
) {
    val isSaved = saveState != StudyCardSaveState.UNSAVED
    val label = when (saveState) {
        StudyCardSaveState.UNSAVED -> "Save"
        StudyCardSaveState.SAVED -> "Saved"
        StudyCardSaveState.DIRTY -> "Update"
    }
    val icon: ImageVector = when (saveState) {
        StudyCardSaveState.UNSAVED -> Icons.Outlined.Download
        StudyCardSaveState.SAVED -> Icons.Outlined.Check
        StudyCardSaveState.DIRTY -> Icons.Outlined.Edit
    }

    Surface(
        onClick = onClick,
        enabled = saveState != StudyCardSaveState.SAVED,
        shape = RoundedCornerShape(20.dp),
        color = if (isSaved) Palette.SurfaceElevated else Palette.Accent,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (isSaved) Palette.TextSecondary else Palette.OnAccent,
                modifier = Modifier.size(14.dp),
            )
            Spacer(modifier = Modifier.width(5.dp))
            Text(
                text = label,
                style = MaterialTheme.typography.bodySmall,
                fontWeight = FontWeight.SemiBold,
                color = if (isSaved) Palette.TextSecondary else Palette.OnAccent,
            )
        }
    }
}

@Composable
private fun FieldRow(
    label: String,
    icon: ImageVector,
    value: String,
    placeholder: String,
    onValueChange: (String) -> Unit,
) {
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = Palette.TextTertiary,
                modifier = Modifier.size(14.dp),
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = Palette.TextSecondary,
            )
        }
        Spacer(modifier = Modifier.height(6.dp))
        Surface(
            shape = RoundedCornerShape(12.dp),
            color = Palette.SurfaceElevated,
            border = BorderStroke(1.dp, Palette.Divider.copy(alpha = 0.6f)),
        ) {
            var focused by remember { mutableStateOf(false) }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 10.dp)
                    .onFocusChanged { focused = it.isFocused },
                textStyle = TextStyle(
                    color = Palette.TextPrimary,
                    fontSize = 15.sp,
                    lineHeight = 20.sp,
                ),
                cursorBrush = SolidColor(Palette.Accent),
                decorationBox = { innerTextField ->
                    if (value.isEmpty() && !focused) {
                        Text(
                            text = placeholder,
                            color = Palette.TextTertiary,
                            fontSize = 15.sp,
                        )
                    }
                    innerTextField()
                },
                maxLines = 8,
            )
        }
    }
}
