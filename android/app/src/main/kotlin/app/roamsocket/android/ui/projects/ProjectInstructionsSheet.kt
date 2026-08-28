package app.roamsocket.android.ui.projects

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
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

/**
 * Modal sheet for editing a project's private instructions. Mirrors
 * the iOS `ProjectDetailView.ProjectInstructionsSheet` inline sheet
 * (`ios/.../Sidebar/ProjectDetailView.swift`).
 *
 * Instructions are project-scoped system prompts that travel with
 * every chat in the project. Saved via [onSave] which is wired to
 * `ChatHistoryStore.updateProjectInstructions`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectInstructionsSheet(
    projectName: String,
    initialText: String,
    onSave: (String) -> Unit,
    onCancel: () -> Unit,
) {
    var text by remember { mutableStateOf(initialText) }
    ModalBottomSheet(onDismissRequest = onCancel) {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            Row {
                Text(
                    "Set project instructions",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onCancel) {
                    Icon(Icons.Outlined.Close, contentDescription = "Close")
                }
            }
            Text(
                "Provide relevant instructions for chats within $projectName. Works alongside profile instructions and the selected style.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 4.dp),
            )
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                placeholder = { Text("Think step by step and show reasoning for complex problems. Use specific examples.") },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(180.dp)
                    .padding(vertical = 8.dp),
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 8.dp),
            ) {
                TextButton(onClick = onCancel, modifier = Modifier.weight(1f)) { Text("Cancel") }
                TextButton(
                    onClick = { onSave(text.trim()) },
                    modifier = Modifier.weight(1f),
                ) { Text("Save instructions") }
            }
        }
    }
}
