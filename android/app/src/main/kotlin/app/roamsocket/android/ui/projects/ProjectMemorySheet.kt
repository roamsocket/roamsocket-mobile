package app.roamsocket.android.ui.projects

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowForward
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Modal sheet for editing a project's private memory. The command
 * field accepts natural-language memory commands and runs them
 * through [ChatHistoryStore.applyProjectMemoryCommand] (which
 * delegates to `MemoryCommandParser`). Successful commands update
 * the memory text in-place; the user can also type directly and hit
 * Save to overwrite.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectMemorySheet(
    projectName: String,
    initialMemory: String,
    onSave: (String) -> Unit,
    onCommand: (String) -> String,
    onCancel: () -> Unit,
) {
    var memory by remember { mutableStateOf(initialMemory) }
    var command by remember { mutableStateOf("") }
    ModalBottomSheet(onDismissRequest = onCancel) {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            Row {
                Text(
                    "Manage project memory",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onCancel) {
                    Icon(Icons.Outlined.Close, contentDescription = "Close")
                }
            }
            Text(
                "Memory is private on this device. Use the field below to forget or remember facts for $projectName. Try \"remember I like coffee\" or \"forget coffee\".",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 4.dp),
            )
            OutlinedTextField(
                value = memory,
                onValueChange = { memory = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(160.dp)
                    .padding(vertical = 8.dp),
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = command,
                    onValueChange = { command = it },
                    placeholder = { Text("remember I like coffee") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                IconButton(
                    onClick = {
                        val next = onCommand(command.trim())
                        memory = next
                        command = ""
                    },
                    enabled = command.isNotBlank(),
                ) { Icon(Icons.Outlined.ArrowForward, contentDescription = "Apply") }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 8.dp),
            ) {
                TextButton(onClick = onCancel, modifier = Modifier.weight(1f)) { Text("Cancel") }
                TextButton(
                    onClick = { onSave(memory) },
                    modifier = Modifier.weight(1f),
                ) { Text("Save") }
            }
        }
    }
}
