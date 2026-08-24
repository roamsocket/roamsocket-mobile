/*
 * Add MCP server bottom sheet. Mirrors the iOS
 * `AddConnectorView` (formerly `AddMCPServerView`).
 *
 * Fields:
 *  * Name
 *  * Description (optional)
 *  * Command (e.g. `npx`, `python`)
 *  * Args (one per line, blank lines ignored)
 *  * Env (KEY=value per line)
 *
 * The caller (MCPViewModel) handles the desktop push.
 */
package app.roamsocket.android.ui.mcp

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddMCPServerSheet(
    onDismiss: () -> Unit,
    onSave: (name: String, description: String, command: String, args: List<String>, env: Map<String, String>) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var name by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var command by remember { mutableStateOf("") }
    var argsRaw by remember { mutableStateOf("") }
    var envRaw by remember { mutableStateOf("") }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "Add connector",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = description,
                onValueChange = { description = it },
                label = { Text("Description") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = command,
                onValueChange = { command = it },
                label = { Text("Command (e.g. npx, python)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = argsRaw,
                onValueChange = { argsRaw = it },
                label = { Text("Args (one per line)") },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(120.dp),
            )
            OutlinedTextField(
                value = envRaw,
                onValueChange = { envRaw = it },
                label = { Text("Env (KEY=value, one per line)") },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(120.dp),
            )
            Spacer(Modifier.height(4.dp))
            Row(
                horizontalArrangement = Arrangement.End,
                modifier = Modifier.fillMaxWidth(),
            ) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                TextButton(
                    onClick = {
                        onSave(
                            name,
                            description,
                            command,
                            argsRaw.lines().map { it.trim() }.filter { it.isNotEmpty() },
                            parseEnv(envRaw),
                        )
                    },
                    enabled = name.isNotBlank() && command.isNotBlank(),
                ) { Text("Save") }
            }
        }
    }
}

private fun parseEnv(text: String): Map<String, String> {
    val out = mutableMapOf<String, String>()
    for (raw in text.lineSequence().map { it.trim() }) {
        if (raw.isEmpty() || raw.startsWith("#")) continue
        val eq = raw.indexOf('=')
        if (eq <= 0) continue
        val key = raw.substring(0, eq).trim()
        var value = raw.substring(eq + 1).trim()
        if (value.length >= 2 &&
            ((value.startsWith("\"") && value.endsWith("\"")) ||
                (value.startsWith("'") && value.endsWith("'")))
        ) {
            value = value.substring(1, value.length - 1)
        }
        if (key.isNotEmpty()) out[key] = value
    }
    return out
}
