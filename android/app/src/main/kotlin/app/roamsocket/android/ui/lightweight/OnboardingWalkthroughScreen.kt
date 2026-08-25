package app.roamsocket.android.ui.lightweight

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Smartphone
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.providers.ProviderId
import kotlinx.coroutines.launch

/**
 * First-launch walkthrough. Four steps:
 *  1. Welcome
 *  2. Lightweight Tasks intro (what they do, why a separate model)
 *  3. Pick linked model (provider + model)
 *  4. Ready
 *
 * The iOS version has 5 steps (Apple Intelligence vs. linked model).
 * Android has no on-device model equivalent, so we drop that branch
 * and only walk through the linked-model path.
 *
 * Mirrors `ios/.../Features/LightweightTasks/OnboardingWalkthroughView.swift`.
 */
@Composable
fun OnboardingWalkthroughScreen(
    store: LightweightTasksStore,
    availableProviders: List<ProviderId>,
    onFinished: () -> Unit,
) {
    var step by remember { mutableStateOf(0) }
    val scope = rememberCoroutineScope()
    val totalSteps = 4

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Palette.Background)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            ProgressBar(step = step, totalSteps = totalSteps)
            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                when (step) {
                    0 -> WelcomeStep()
                    1 -> LightweightIntroStep()
                    2 -> PickLinkedModelStep(
                        store = store,
                        availableProviders = availableProviders,
                    )
                    3 -> ReadyStep()
                }
            }
            BottomBar(
                step = step,
                totalSteps = totalSteps,
                canContinue = canContinue(step, store),
                onBack = { if (step > 0) step -= 1 },
                onPrimary = {
                    if (step < totalSteps - 1) {
                        step += 1
                    } else {
                        store.update { it.copy(walkthroughCompleted = true) }
                        onFinished()
                    }
                },
            )
        }
    }
}

@Composable
private fun ProgressBar(step: Int, totalSteps: Int) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 12.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(RoundedCornerShape(50))
                .background(Palette.SurfaceElevated),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(fraction = (step + 1).toFloat() / totalSteps.toFloat())
                    .height(4.dp)
                    .clip(RoundedCornerShape(50))
                    .background(Palette.Accent),
            )
        }
    }
}

@Composable
private fun BottomBar(
    step: Int,
    totalSteps: Int,
    canContinue: Boolean,
    onBack: () -> Unit,
    onPrimary: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (step > 0) {
            Text(
                text = "Back",
                color = Palette.TextSecondary,
                fontSize = 16.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(Palette.SurfaceElevated)
                    .padding(horizontal = 18.dp, vertical = 12.dp)
                    .clickable(onClick = onBack),
            )
        }
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = if (step == totalSteps - 1) "Get started" else "Continue",
            color = if (canContinue) Palette.OnAccent else Palette.TextTertiary,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(if (canContinue) Palette.Accent else Palette.SurfaceElevated)
                .padding(horizontal = 24.dp, vertical = 12.dp)
                .clickable(enabled = canContinue, onClick = onPrimary),
        )
    }
}

private fun canContinue(step: Int, store: LightweightTasksStore): Boolean = when (step) {
    // The pick step doesn't *block* continuation — the user can finish
    // the walkthrough and pick a model later from Settings.
    else -> true
}

// --- Step content ---------------------------------------------------------

@Composable
private fun WelcomeStep() {
    WalkthroughPage(
        icon = Icons.Outlined.Smartphone,
        title = "Welcome to RoamSocket",
        body = """
        Native chat and coding on your Android phone.

        • Chat talks to providers you bring (Anthropic, OpenAI, Google, and more).
        • Code pairs with the desktop companion for real tools, diffs, and pull requests.
        • Local helpers keep the small jobs (titles, names, summaries) on the cheap.
        """.trimIndent(),
    )
}

@Composable
private fun LightweightIntroStep() {
    WalkthroughPage(
        icon = Icons.Outlined.Bolt,
        title = "Lightweight Tasks",
        body = """
        Short helper jobs use a separate brain from your main chat model:

        • Chat titles in Recents
        • Artifact names
        • Commit message suggestions
        • Thinking summaries

        You can use any model you already pay for. On Android there's no on-device fallback yet, so you'll want a provider with an API key handy.
        """.trimIndent(),
    )
}

@Composable
private fun PickLinkedModelStep(
    store: LightweightTasksStore,
    availableProviders: List<ProviderId>,
) {
    val current = store.settings.value
    var providerMenuOpen by remember { mutableStateOf(false) }
    var modelMenuOpen by remember { mutableStateOf(false) }
    val models = remember(current.linkedProviderRaw) {
        // We don't have a preloaded catalog on Android during onboarding;
        // the user types the model id. Once they leave the walkthrough,
        // the Settings → Lightweight Tasks sheet can listModels() lazily.
        emptyList<String>()
    }
    var modelInput by remember(current.linkedModelID) {
        mutableStateOf(current.linkedModelID.orEmpty())
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        StepHeading(
            icon = Icons.Outlined.AutoAwesome,
            title = "Choose a backend",
            subtitle = "You can change this anytime in Settings → Lightweight Tasks.",
        )
        BackendCard(
            mode = LightweightTasksSettings.Mode.LINKED_MODEL,
            selected = true,
        )

        // Linked-model picker — provider + model.
        Surface(
            color = Palette.Surface,
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    text = "Linked model",
                    color = Palette.TextPrimary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Box {
                    PickerRow(
                        label = current.linkedProvider?.displayName ?: "Select provider…",
                        placeholder = current.linkedProvider == null,
                        onClick = { providerMenuOpen = true },
                    )
                    DropdownMenu(
                        expanded = providerMenuOpen,
                        onDismissRequest = { providerMenuOpen = false },
                        modifier = Modifier.background(Palette.Surface),
                    ) {
                        availableProviders.forEach { p ->
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        text = p.displayName,
                                        color = Palette.TextPrimary,
                                    )
                                },
                                onClick = {
                                    store.update { it.copy(linkedProviderRaw = p.rawValue) }
                                    providerMenuOpen = false
                                },
                            )
                        }
                    }
                }
                if (current.linkedProvider != null) {
                    ModelInputField(
                        value = modelInput,
                        onValueChange = {
                            modelInput = it
                            store.update { settings ->
                                settings.copy(linkedModelID = it.trim().takeIf { v -> v.isNotEmpty() })
                            }
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun ReadyStep() {
    WalkthroughPage(
        icon = Icons.Outlined.Check,
        title = "You're ready",
        body = "We'll keep the small jobs cheap and only call the linked model when you actually ask for it. Tap **Get started** to open RoamSocket.",
    )
}

@Composable
private fun WalkthroughPage(icon: ImageVector, title: String, body: String) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        StepIcon(icon = icon)
        Spacer(modifier = Modifier.height(24.dp))
        Text(
            text = title,
            color = Palette.TextPrimary,
            fontSize = 26.sp,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = body,
            color = Palette.TextSecondary,
            fontSize = 15.sp,
            textAlign = TextAlign.Start,
            lineHeight = 22.sp,
        )
    }
}

@Composable
private fun StepHeading(icon: ImageVector, title: String, subtitle: String?) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StepIcon(icon = icon)
            Spacer(modifier = Modifier.width(12.dp))
            Text(
                text = title,
                color = Palette.TextPrimary,
                fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
        if (subtitle != null) {
            Text(
                text = subtitle,
                color = Palette.TextSecondary,
                fontSize = 14.sp,
            )
        }
    }
}

@Composable
private fun StepIcon(icon: ImageVector) {
    Box(
        modifier = Modifier
            .size(56.dp)
            .clip(CircleShape)
            .background(Palette.SurfaceElevated),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Palette.Accent,
            modifier = Modifier.size(28.dp),
        )
    }
}

@Composable
private fun BackendCard(mode: LightweightTasksSettings.Mode, selected: Boolean) {
    val border = if (selected) Palette.Accent else Palette.Divider
    Surface(
        color = Palette.Surface,
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
        border = androidx.compose.foundation.BorderStroke(
            width = if (selected) 2.dp else 1.dp,
            color = border,
        ),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                text = mode.displayName,
                color = Palette.TextPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = mode.detail,
                color = Palette.TextSecondary,
                fontSize = 13.sp,
            )
        }
    }
}

@Composable
private fun PickerRow(label: String, placeholder: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Palette.SurfaceElevated)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            color = if (placeholder) Palette.TextTertiary else Palette.TextPrimary,
            fontSize = 16.sp,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = "▾",
            color = Palette.TextSecondary,
            fontSize = 14.sp,
        )
    }
}

@Composable
private fun ModelInputField(value: String, onValueChange: (String) -> Unit) {
    androidx.compose.foundation.text.BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        textStyle = androidx.compose.ui.text.TextStyle(
            color = Palette.TextPrimary,
            fontSize = 15.sp,
        ),
        cursorBrush = androidx.compose.ui.graphics.SolidColor(Palette.Accent),
        decorationBox = { inner ->
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Palette.SurfaceElevated)
                    .padding(horizontal = 16.dp, vertical = 14.dp),
            ) {
                if (value.isEmpty()) {
                    Text(
                        text = "e.g. gpt-4o-mini · claude-3-5-haiku-latest",
                        color = Palette.TextTertiary,
                        fontSize = 14.sp,
                    )
                }
                inner()
            }
        },
        modifier = Modifier.fillMaxWidth(),
    )
}
