package app.roamsocket.android.ui.vision

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.Camera
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Reorder
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import app.roamsocket.android.ui.LocalNavigateToSettings
import app.roamsocket.android.ui.markdown.MarkdownText
import app.roamsocket.core.providers.AIModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// ---------------------------------------------------------------------
// Vision mode selection (mirrors iOS VisionPromptStore.builtInPresets)
// ---------------------------------------------------------------------

/**
 * The task mode that shapes the first analysis prompt.
 *
 * Prompt copy is ported verbatim from the iOS built-ins
 * (`VisionPromptStore.builtInPresets`); "General analysis" carries the
 * iOS `VisionViewModel.defaultAnalysisPrompt` fallback used when a
 * preset's prompt is empty. Entry order matches iOS `sortOrder`.
 */
enum class VisionMode(val label: String, val systemInstruction: String) {
    GENERAL(
        label = "General analysis",
        systemInstruction = """
            Analyze this photo for the user.

            **If this is a quiz, test, worksheet, or homework** (true/false, multiple choice, short answer, or several discrete questions), use this layout instead of the general one:

            1. One-line intro naming the question type and count (e.g. “Here are the answers to the four true/false questions on your screen.”).
            2. For each question:

            ## Question N

            - **Text:** Restate the full question (and options if multiple choice).
            - **Answer:** Bold the correct choice, True/False, number, or short phrase.
            - **Reason:** One or two concise sentences of explanation.

            Separate questions with `---`. Do not open with a photo description.

            **Otherwise** (general photos), structure your reply like this:

            ## Answer
            Start with the key takeaway, result, identification, or recommendation in 1–3 short sentences (or a tight bullet list). Put what the user needs first — not a scenic description.

            ## Details
            Brief supporting facts: notable objects, readable text (transcribe if useful), layout, materials, condition, or risks.

            ## Notes (optional)
            Uncertainty, missing context, or follow-up suggestions only if helpful.

            Be concise. Never open with “This photo shows…” or a long scene description before the answer.
        """.trimIndent(),
    ),
    TRANSCRIBE(
        label = "Transcribe text",
        systemInstruction = """
            Transcribe all readable text in this photo.

            ## Transcript
            Put the full transcription first, preserving layout with line breaks where helpful.

            ## Notes
            Only after the transcript: note anything partially obscured, uncertain, or unreadable. Do not invent text that is not visible.
        """.trimIndent(),
    ),
    IDENTIFY(
        label = "Identify objects",
        systemInstruction = """
            Identify what is in this photo.

            ## Answer
            Lead with a short inventory of the main objects, brands, products, and materials (bullets).

            ## Details
            For each item, add useful detail only if needed (color, condition, type). Mark guesses clearly.
        """.trimIndent(),
    ),
    QUIZ_HOMEWORK(
        label = "Quiz / homework",
        systemInstruction = """
            This photo shows a quiz, worksheet, test, or homework (true/false, multiple choice, short answer, or mixed).

            Break down every visible question. Structure your reply exactly like this:

            1. **One-line intro** (no heading): e.g. “Here are the answers to the four true/false questions on your screen.” Name the question type and count when clear.

            2. **Then for each question**, use this per-item layout (repeat for Q1, Q2, …):

            ## Question N

            - **Text:** Restate the full question (and options if multiple choice).
            - **Answer:** The correct choice, True/False, number, or short phrase — bold the key answer.
            - **Reason:** One or two concise sentences explaining why (definition, concept, or quick calculation). Not a lecture.

            Separate questions with a horizontal rule (`---`).

            **Multiple choice tip:** In **Answer**, put the letter/label and the option text (e.g. **B — Online retail**). You may also bold the chosen phrase inside **Text** if that reads cleaner.

            Rules:
            - Answer every fully visible question. If the crop cuts something off, still answer what is visible and note what is missing at the end.
            - Do not open with a photo description (“This image shows…”, “I can see a worksheet…”).
            - Prefer scannable bullets over long paragraphs. Keep reasons short.
            - If only one question is visible, still use the Question / Text / Answer / Reason layout.
            - End with a brief optional line only if helpful (e.g. “Take another clear photo for the next section.”).
        """.trimIndent(),
    ),
    ACCESSIBILITY(
        label = "Accessibility",
        systemInstruction = """
            Write a clear accessibility description for someone who cannot see this photo.

            ## Summary
            One short sentence with the essential subject and setting first.

            ## Details
            Then cover important text, colors, spatial layout, and secondary elements. Be concise but complete.
        """.trimIndent(),
    ),
    SAFETY_CHECK(
        label = "Safety check",
        systemInstruction = """
            Assess practical hazards or safety issues in this photo.

            ## Findings
            Lead with the risk list by severity (or “No obvious hazards” if clear).

            ## Next steps
            Suggest simple actions when relevant.

            Do not open with a general description of the scene.
        """.trimIndent(),
    ),
    ;

    companion object {
        fun fromIndex(index: Int): VisionMode = entries.getOrElse(index) { GENERAL }
    }
}

// ---------------------------------------------------------------------
// Main Vision screen
// ---------------------------------------------------------------------

/**
 * Full-screen Vision mode. Mirrors the iOS `VisionView` flow:
 *
 * 1. Live camera viewfinder + mode selector pills + optional prompt.
 * 2. Tap shutter / pick → capture → frozen photo + corner brackets overlay.
 * 3. Bottom sheet slides up: "Analysis" header with toolbar, thread, follow-up.
 * 4. Mode pills and prompt field pre-fill the analysis so the user can
 *    quickly re-analyze with a different instruction.
 *
 * Ephemeral: no chat history persistence — matches iOS `VisionView`.
 */
@Composable
fun VisionScreen(
    onClose: () -> Unit,
    viewModel: VisionViewModel = viewModel(
        key = "VisionScreen",
        factory = VisionViewModel.Factory,
    ),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val navigateToSettings = LocalNavigateToSettings.current

    // Track selected mode pill for the live view.
    var selectedMode by remember { mutableStateOf(VisionMode.GENERAL) }

    // Re-analyze sheet state.
    var showReanalyzeSheet by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        when (state.phase) {
            VisionViewModel.Phase.Live -> LiveView(
                state = state,
                selectedMode = selectedMode,
                onModeChange = { selectedMode = it },
                onClose = onClose,
                onPicked = { uri -> onImagePicked(context, viewModel, uri, selectedMode) },
                onSelectModel = viewModel::selectModel,
                onOpenSettings = navigateToSettings,
            )

            VisionViewModel.Phase.Analyzing,
            VisionViewModel.Phase.Result,
            VisionViewModel.Phase.Failed -> AnalysisView(
                state = state,
                selectedMode = selectedMode,
                onClose = onClose,
                onRetake = viewModel::retake,
                onRetry = viewModel::retry,
                onUpdateDraft = viewModel::updateDraft,
                onSendFollowUp = viewModel::sendFollowUp,
                onSelectModel = viewModel::selectModel,
                onOpenSettings = navigateToSettings,
                onDismissError = viewModel::dismissError,
                onReanalyze = { showReanalyzeSheet = true },
                onModeChange = { selectedMode = it },
            )
        }
    }

    // Re-analyze bottom sheet.
    if (showReanalyzeSheet) {
        ReanalyzeSheet(
            selectedMode = selectedMode,
            onModeChange = { selectedMode = it },
            onRun = { newMode ->
                showReanalyzeSheet = false
                selectedMode = newMode
                viewModel.retake()
                // After retake the UI will show LiveView; the user taps
                // shutter again. We could auto-re-trigger here, but iOS
                // also requires a second tap, so we stop here.
            },
            onDismiss = { showReanalyzeSheet = false },
        )
    }
}

// ---------------------------------------------------------------------
// Live viewfinder
// ---------------------------------------------------------------------

@Composable
private fun LiveView(
    state: VisionViewModel.UiState,
    selectedMode: VisionMode,
    onModeChange: (VisionMode) -> Unit,
    onClose: () -> Unit,
    onPicked: (Uri) -> Unit,
    onSelectModel: (AIModel) -> Unit,
    onOpenSettings: () -> Unit,
) {
    val context = LocalContext.current
    var hasCameraPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    val cameraPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted -> hasCameraPermission = granted }
    val galleryLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri -> if (uri != null) onPicked(uri) }
    val canShutter = state.selectedModel != null &&
        !state.missingApiKey &&
        state.visionModels.isNotEmpty()

    var showModelPicker by remember { mutableStateOf(false) }
    var imageCapture by remember { mutableStateOf<ImageCapture?>(null) }
    var promptText by remember { mutableStateOf("") }

    Box(modifier = Modifier.fillMaxSize()) {
        // Full-screen viewfinder.
        if (hasCameraPermission) {
            CameraPreview(
                modifier = Modifier.fillMaxSize(),
                onImageCaptureReady = { imageCapture = it },
            )
        } else {
            CameraPermissionPrompt(onRequest = { cameraPermissionLauncher.launch(Manifest.permission.CAMERA) })
        }

        // Top chrome — close + model pill.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ChromeCircleButton(
                onClick = onClose,
                contentDescription = "Close Vision",
                icon = Icons.Outlined.Close,
            )
            Spacer(Modifier.weight(1f))
            ModelPill(
                label = state.selectedModel?.let { AIModel.prettifiedDisplayName(it.modelID) } ?: "Choose model",
                onClick = { showModelPicker = true },
            )
        }

        // Bottom controls — overlay card matching iOS style.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // Mode selector pills (horizontal scroll).
            ModePillRow(
                selectedMode = selectedMode,
                onModeChange = onModeChange,
            )

            Spacer(Modifier.height(12.dp))

            // Optional prompt text field.
            OptionalPromptField(
                text = promptText,
                onTextChange = { promptText = it },
            )

            Spacer(Modifier.height(16.dp))

            // Camera controls row: gallery | shutter | model.
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ChromeCircleButton(
                    onClick = {
                        galleryLauncher.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                        )
                    },
                    contentDescription = "Pick from gallery",
                    icon = Icons.Outlined.PhotoLibrary,
                )
                ShutterButton(
                    enabled = canShutter && imageCapture != null,
                    onClick = {
                        if (state.missingApiKey) {
                            onOpenSettings()
                            return@ShutterButton
                        }
                        val capture = imageCapture ?: return@ShutterButton
                        captureToCache(
                            context = context,
                            imageCapture = capture,
                            onResult = { uri -> onPicked(uri) },
                            onError = { Log.e("VisionScreen", "capture failed", it) },
                        )
                    },
                )
                ChromeCircleButton(
                    onClick = { showModelPicker = true },
                    contentDescription = "Pick vision model",
                    icon = Icons.Outlined.Visibility,
                )
            }
        }

        // Inline error pill.
        state.errorMessage?.let { msg ->
            ErrorPill(
                message = msg,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .padding(top = 80.dp, start = 16.dp, end = 16.dp),
            )
        }
    }

    if (showModelPicker) {
        VisionModelPickerSheet(
            models = state.visionModels,
            selected = state.selectedModel,
            onSelect = { picked ->
                onSelectModel(picked)
                showModelPicker = false
            },
            onDismiss = { showModelPicker = false },
        )
    }
}

// ---------------------------------------------------------------------
// Mode pill row (iOS: General analysis / Transcribe text / Identify object)
// ---------------------------------------------------------------------

@Composable
private fun ModePillRow(
    selectedMode: VisionMode,
    onModeChange: (VisionMode) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        VisionMode.entries.forEach { mode ->
            ModePill(
                label = mode.label,
                selected = mode == selectedMode,
                onClick = { onModeChange(mode) },
            )
        }
    }
}

@Composable
private fun ModePill(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(20.dp),
        color = if (selected) {
            Color(0xFF6AA9FF) // iOS active pill: light blue
        } else {
            Color.White.copy(alpha = 0.12f)
        },
        contentColor = if (selected) Color.Black else Color.White,
        border = if (!selected) BorderStroke(1.dp, Color.White.copy(alpha = 0.25f)) else null,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}

// ---------------------------------------------------------------------
// Optional prompt text field (iOS: "Optional prompt for this shot...")
// ---------------------------------------------------------------------

@Composable
private fun OptionalPromptField(
    text: String,
    onTextChange: (String) -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = Color.White.copy(alpha = 0.12f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        OutlinedTextField(
            value = text,
            onValueChange = onTextChange,
            modifier = Modifier.fillMaxWidth(),
            placeholder = {
                Text(
                    text = "Optional prompt for this shot…",
                    color = Color.White.copy(alpha = 0.5f),
                )
            },
            colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                focusedTextColor = Color.White,
                unfocusedTextColor = Color.White,
                cursorColor = Color(0xFF6AA9FF),
                focusedBorderColor = Color.Transparent,
                unfocusedBorderColor = Color.Transparent,
            ),
            maxLines = 2,
            shape = RoundedCornerShape(24.dp),
        )
    }
}

// ---------------------------------------------------------------------
// Analysis surface (frozen image + bottom sheet overlay)
// ---------------------------------------------------------------------

@Composable
private fun AnalysisView(
    state: VisionViewModel.UiState,
    selectedMode: VisionMode,
    onClose: () -> Unit,
    onRetake: () -> Unit,
    onRetry: () -> Unit,
    onUpdateDraft: (String) -> Unit,
    onSendFollowUp: () -> Unit,
    onSelectModel: (AIModel) -> Unit,
    onOpenSettings: () -> Unit,
    onDismissError: () -> Unit,
    onReanalyze: () -> Unit,
    onModeChange: (VisionMode) -> Unit,
) {
    var showModelPicker by remember { mutableStateOf(false) }
    var imageContainerSize by remember { mutableStateOf(IntSize.Zero) }
    val listState = rememberLazyListState()
    val clipboardManager = LocalClipboardManager.current

    LaunchedEffect(state.turns.size) {
        if (state.turns.isNotEmpty()) {
            listState.animateScrollToItem(state.turns.lastIndex)
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        // Image layer — full bleed black + captured photo + corner brackets.
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black),
        ) {
            state.imageBytes?.let { bytes ->
                val bitmap = remember(bytes) {
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                }
                if (bitmap != null) {
                    Image(
                        bitmap = bitmap.asImageBitmap(),
                        contentDescription = "Captured photo",
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .fillMaxSize()
                            .onSizeChanged { imageContainerSize = it }
                            .graphicsLayer {
                                // Rotate for emulated landscape camera if needed.
                                // The emulator camera delivers rotated JPEG bytes;
                                // this corrects the on-screen orientation.
                                rotationZ = 0f
                            },
                    )
                }
            }

            // Corner bracket overlay — matches iOS "targeting reticle" style.
            if (imageContainerSize.width > 0 && imageContainerSize.height > 0) {
                CornerBracketOverlay(
                    containerSize = imageContainerSize,
                    modifier = Modifier.matchParentSize(),
                )
            }
        }

        // Bottom sheet overlay — slides up over the image.
        AnalysisBottomSheet(
            state = state,
            selectedMode = selectedMode,
            onModeChange = onModeChange,
            onRetake = onRetake,
            onReanalyze = onReanalyze,
            onClose = onClose,
            onUpdateDraft = onUpdateDraft,
            onSendFollowUp = onSendFollowUp,
            onDismissError = onDismissError,
            onCopyAnalysis = { text ->
                clipboardManager.setText(AnnotatedString(text))
            },
        )
    }

    // Failed dialog.
    if (state.phase == VisionViewModel.Phase.Failed && state.imageBytes != null) {
        AlertDialog(
            onDismissRequest = onDismissError,
            title = { Text("Analysis failed") },
            text = { Text(state.errorMessage ?: "Unknown error") },
            confirmButton = { TextButton(onClick = onRetry) { Text("Retry") } },
            dismissButton = { TextButton(onClick = onRetake) { Text("Retake") } },
        )
    }

    // Model picker sheet.
    if (showModelPicker) {
        VisionModelPickerSheet(
            models = state.visionModels,
            selected = state.selectedModel,
            onSelect = { picked ->
                onSelectModel(picked)
                showModelPicker = false
            },
            onDismiss = { showModelPicker = false },
        )
    }
}

// ---------------------------------------------------------------------
// Corner bracket overlay (iOS targeting reticle)
// ---------------------------------------------------------------------

@Composable
private fun CornerBracketOverlay(
    containerSize: IntSize,
    modifier: Modifier = Modifier,
    bracketLength: Float = 24f,
    strokeWidth: Float = 3f,
    color: Color = Color.White,
) {
    Canvas(modifier = modifier) {
        val w = size.width
        val h = size.height
        val imgLeft = (w - containerSize.width) / 2f + 8f
        val imgTop = (h - containerSize.height) / 2f + 8f
        val imgRight = imgLeft + containerSize.width - 16f
        val imgBottom = imgTop + containerSize.height - 16f

        val stroke = Stroke(width = strokeWidth)

        // Top-left corner bracket.
        // Arc center at (imgLeft, imgTop), bounding box top-left = (imgLeft - L, imgTop - L).
        drawArc(
            color = color,
            startAngle = 180f,
            sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(imgLeft - bracketLength, imgTop - bracketLength),
            size = Size(bracketLength * 2, bracketLength * 2),
            style = stroke,
        )
        // Top-right corner bracket.
        drawArc(
            color = color,
            startAngle = 270f,
            sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(imgRight - bracketLength, imgTop - bracketLength),
            size = Size(bracketLength * 2, bracketLength * 2),
            style = stroke,
        )
        // Bottom-left corner bracket.
        drawArc(
            color = color,
            startAngle = 90f,
            sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(imgLeft - bracketLength, imgBottom - bracketLength),
            size = Size(bracketLength * 2, bracketLength * 2),
            style = stroke,
        )
        // Bottom-right corner bracket.
        drawArc(
            color = color,
            startAngle = 0f,
            sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(imgRight - bracketLength, imgBottom - bracketLength),
            size = Size(bracketLength * 2, bracketLength * 2),
            style = stroke,
        )
    }
}

// ---------------------------------------------------------------------
// Analysis bottom sheet (iOS-style: dark overlay over the image)
// ---------------------------------------------------------------------

@Composable
private fun AnalysisBottomSheet(
    state: VisionViewModel.UiState,
    selectedMode: VisionMode,
    onModeChange: (VisionMode) -> Unit,
    onRetake: () -> Unit,
    onReanalyze: () -> Unit,
    onClose: () -> Unit,
    onUpdateDraft: (String) -> Unit,
    onSendFollowUp: () -> Unit,
    onDismissError: () -> Unit,
    onCopyAnalysis: (String) -> Unit,
) {
    val isLoading = state.isAnalyzing || state.isReplying

    Column(
        modifier = Modifier
            .fillMaxSize()
            .navigationBarsPadding()
            .imePadding(),
    ) {
        Spacer(Modifier.weight(1f))

        // Bottom sheet card.
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
            color = Color(0xFF1C1C1E), // iOS sheet background
        ) {
            Column {
                // Drag handle.
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 10.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        modifier = Modifier
                            .width(36.dp)
                            .height(5.dp)
                            .clip(RoundedCornerShape(3.dp))
                            .background(Color.White.copy(alpha = 0.3f)),
                    )
                }

                // Header row: title + toolbar buttons + model picker.
                AnalysisHeader(
                    isLoading = isLoading,
                    modelName = state.selectedModel?.let { AIModel.prettifiedDisplayName(it.modelID) } ?: "—",
                    analysisText = state.turns.lastOrNull()?.text
                        ?: state.analysisText,
                    onCopy = { text -> onCopyAnalysis(text) },
                    onReanalyze = onReanalyze,
                    onRetake = onRetake,
                    onClose = onClose,
                )

                HorizontalDivider(color = Color.White.copy(alpha = 0.1f))

                // Mode pills row (inside the sheet).
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 10.dp)
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    VisionMode.entries.forEach { mode ->
                        ModePill(
                            label = mode.label,
                            selected = mode == selectedMode,
                            onClick = { onModeChange(mode) },
                        )
                    }
                }

                // Error pill.
                state.errorMessage?.let { msg ->
                    ErrorPill(
                        message = msg,
                        onDismiss = onDismissError,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                    )
                }

                // Scrollable thread / skeleton.
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 80.dp, max = 280.dp),
                    state = rememberLazyListState(),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    // First analysis or follow-up turns.
                    if (state.turns.isNotEmpty()) {
                        itemsIndexed(
                            items = state.turns,
                            key = { idx, _ -> "turn_$idx" },
                        ) { _, turn -> TurnBubble(turn = turn) }
                    } else if (state.analysisText.isNotEmpty()) {
                        item("headline") {
                            TurnBubble(
                                turn = VisionViewModel.Turn(
                                    role = VisionViewModel.Turn.Role.Assistant,
                                    text = state.analysisText,
                                ),
                            )
                        }
                    }

                    // Analyzing skeleton.
                    if (isLoading && state.turns.isEmpty()) {
                        item("skeleton") { AnalyzingSkeleton(state.isAnalyzing) }
                    }
                }

                // Follow-up composer.
                FollowUpComposer(
                    draft = state.draft,
                    enabled = state.phase == VisionViewModel.Phase.Result && !isLoading,
                    sending = state.isReplying,
                    onDraftChange = onUpdateDraft,
                    onSend = onSendFollowUp,
                    onOpenSettings = onClose,
                    missingKey = state.missingApiKey,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
        }
    }
}

// ---------------------------------------------------------------------
// Analysis header (iOS: "Analysis" title + toolbar + model picker)
// ---------------------------------------------------------------------

@Composable
private fun AnalysisHeader(
    isLoading: Boolean,
    modelName: String,
    analysisText: String,
    onCopy: (String) -> Unit,
    onReanalyze: () -> Unit,
    onRetake: () -> Unit,
    onClose: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Left: Close / back button.
        IconButton(onClick = onClose) {
            Icon(
                imageVector = Icons.Outlined.Close,
                contentDescription = "Close",
                tint = Color.White,
                modifier = Modifier.size(22.dp),
            )
        }

        Spacer(Modifier.weight(1f))

        // Toolbar icons (match iOS: copy, layers, format, camera).
        ToolbarIcon(
            icon = Icons.Outlined.ContentCopy,
            contentDescription = "Copy",
            enabled = analysisText.isNotEmpty(),
            onClick = { onCopy(analysisText) },
        )
        ToolbarIcon(
            icon = Icons.Outlined.Layers,
            contentDescription = "Layers",
            enabled = false,
            onClick = { /* no-op */ },
        )
        ToolbarIcon(
            icon = Icons.Outlined.Reorder,
            contentDescription = "Format",
            enabled = false,
            onClick = { /* no-op */ },
        )
        ToolbarIcon(
            icon = Icons.Outlined.Camera,
            contentDescription = "Retake",
            enabled = true,
            onClick = onRetake,
        )

        Spacer(Modifier.width(8.dp))

        // Model pill (right side).
        Surface(
            shape = RoundedCornerShape(16.dp),
            color = Color.White.copy(alpha = 0.12f),
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = modelName.take(10),
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.8f),
                    maxLines = 1,
                )
                Icon(
                    imageVector = Icons.Outlined.ChevronRight,
                    contentDescription = null,
                    tint = Color.White.copy(alpha = 0.6f),
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

@Composable
private fun ToolbarIcon(
    icon: ImageVector,
    contentDescription: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    IconButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.size(36.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = if (enabled) Color.White.copy(alpha = 0.85f) else Color.White.copy(alpha = 0.3f),
            modifier = Modifier.size(20.dp),
        )
    }
}

// ---------------------------------------------------------------------
// Analyzing skeleton (iOS: spinner + status text + shimmer bars)
// ---------------------------------------------------------------------

@Composable
private fun AnalyzingSkeleton(isFirstTurn: Boolean) {
    val infiniteTransition = rememberInfiniteTransition(label = "shimmer")
    val shimmer by infiniteTransition.animateFloat(
        initialValue = 0.3f,
        targetValue = 0.7f,
        animationSpec = infiniteRepeatable(
            animation = tween(900, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "shimmer",
    )

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Status text (matches iOS "Looking at the photo with web results...").
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (isFirstTurn) {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    strokeWidth = 2.dp,
                    color = Color(0xFF6AA9FF),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "Looking at the photo…",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.6f),
                )
            }
        }

        // Skeleton bars.
        listOf(0.85f, 0.6f, 0.75f).forEach { fraction ->
            Box(
                modifier = Modifier
                    .fillMaxWidth(fraction)
                    .height(12.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(Color.White.copy(alpha = shimmer * 0.4f)),
            )
        }
    }
}

// ---------------------------------------------------------------------
// Re-analyze sheet (iOS "Re-analyze" modal)
// ---------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReanalyzeSheet(
    selectedMode: VisionMode,
    onModeChange: (VisionMode) -> Unit,
    onRun: (VisionMode) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var taskPrompt by remember { mutableStateOf("") }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Color(0xFF1C1C1E),
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
                        .background(Color.White.copy(alpha = 0.3f)),
                )
            }
        },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .navigationBarsPadding()
                .padding(bottom = 24.dp),
        ) {
            // Header.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Outlined.Close, contentDescription = "Close", tint = Color.White)
                }
                Spacer(Modifier.weight(1f))
                Text(
                    text = "Re-analyze",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                )
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { onRun(selectedMode) }) {
                    Text(
                        text = "Run",
                        color = Color(0xFF6AA9FF),
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }

            Spacer(Modifier.height(4.dp))

            Text(
                text = "Same photo, new instructions.",
                style = MaterialTheme.typography.bodySmall,
                color = Color.White.copy(alpha = 0.5f),
                modifier = Modifier.padding(start = 16.dp),
            )

            Spacer(Modifier.height(20.dp))

            // Task prompt field.
            Text(
                text = "Task prompt",
                style = MaterialTheme.typography.bodySmall,
                color = Color.White.copy(alpha = 0.7f),
                modifier = Modifier.padding(start = 4.dp, bottom = 8.dp),
            )
            OutlinedTextField(
                value = taskPrompt,
                onValueChange = { taskPrompt = it },
                modifier = Modifier.fillMaxWidth(),
                placeholder = {
                    Text("Empty = general analysis", color = Color.White.copy(alpha = 0.35f))
                },
                colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    cursorColor = Color(0xFF6AA9FF),
                    focusedBorderColor = Color(0xFF6AA9FF),
                    unfocusedBorderColor = Color.White.copy(alpha = 0.2f),
                    focusedContainerColor = Color.White.copy(alpha = 0.06f),
                    unfocusedContainerColor = Color.White.copy(alpha = 0.06f),
                ),
                minLines = 3,
                maxLines = 5,
                shape = RoundedCornerShape(12.dp),
            )

            Spacer(Modifier.height(20.dp))

            // Presets.
            Text(
                text = "Presets",
                style = MaterialTheme.typography.bodySmall,
                color = Color.White.copy(alpha = 0.7f),
                modifier = Modifier.padding(start = 4.dp, bottom = 10.dp),
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                VisionMode.entries.forEach { mode ->
                    ModePill(
                        label = mode.label,
                        selected = mode == selectedMode,
                        onClick = { onModeChange(mode) },
                    )
                }
            }

            Spacer(Modifier.height(24.dp))

            // Run button.
            Button(
                onClick = { onRun(selectedMode) },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
                shape = RoundedCornerShape(14.dp),
                colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                    containerColor = Color(0xFF6AA9FF),
                    contentColor = Color.Black,
                ),
            ) {
                Text(
                    text = "Re-analyze photo",
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

// ---------------------------------------------------------------------
// Camera preview (CameraX)
// ---------------------------------------------------------------------

@Composable
private fun CameraPreview(
    modifier: Modifier = Modifier,
    onImageCaptureReady: (ImageCapture) -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val previewView = remember { PreviewView(context) }

    LaunchedEffect(previewView) {
        val provider = awaitCameraProvider(context)
        val preview = Preview.Builder().build().also {
            it.setSurfaceProvider(previewView.surfaceProvider)
        }
        val capture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()
        provider.unbindAll()
        provider.bindToLifecycle(
            lifecycleOwner,
            CameraSelector.DEFAULT_BACK_CAMERA,
            preview,
            capture,
        )
        onImageCaptureReady(capture)
    }
    DisposableEffect(Unit) {
        onDispose { /* CameraX is lifecycle-bound, nothing to do. */ }
    }

    AndroidView(
        factory = { previewView },
        modifier = modifier,
    )
}

@Composable
private fun CameraPermissionPrompt(onRequest: () -> Unit) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.padding(32.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Camera,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(48.dp),
            )
            Text(
                text = "Camera access",
                style = MaterialTheme.typography.titleLarge,
                color = Color.White,
            )
            Text(
                text = "Vision needs the camera so you can capture photos for analysis. " +
                    "You can still pick images from your gallery without it.",
                style = MaterialTheme.typography.bodyMedium,
                color = Color.White.copy(alpha = 0.8f),
            )
            Button(onClick = onRequest) { Text("Allow camera") }
        }
    }
}

// ---------------------------------------------------------------------
// Model picker
// ---------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VisionModelPickerSheet(
    models: List<AIModel>,
    selected: AIModel?,
    onSelect: (AIModel) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Color(0xFF1C1C1E),
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
                        .background(Color.White.copy(alpha = 0.3f)),
                )
            }
        },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .navigationBarsPadding()
                .padding(bottom = 24.dp),
        ) {
            Text(
                text = "Vision model",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
                modifier = Modifier.padding(start = 8.dp, top = 4.dp, bottom = 16.dp),
            )

            if (models.isEmpty()) {
                Text(
                    text = "No vision-capable models in the current catalog. " +
                        "Add an API key for Anthropic, OpenAI, Google, xAI, " +
                        "OpenRouter, or a custom OpenAI-compatible provider in Settings.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = Color.White.copy(alpha = 0.6f),
                    modifier = Modifier.padding(8.dp),
                )
            } else {
                // Group by provider.
                val grouped = models.groupBy { it.provider.displayName }
                grouped.forEach { (provider, providerModels) ->
                    Text(
                        text = provider,
                        style = MaterialTheme.typography.labelMedium,
                        color = Color.White.copy(alpha = 0.5f),
                        modifier = Modifier.padding(start = 12.dp, top = 8.dp, bottom = 4.dp),
                    )
                    providerModels.forEach { model ->
                        val isSelected = model.id == selected?.id
                        Surface(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .clickable { onSelect(model) },
                            color = if (isSelected) Color.White.copy(alpha = 0.08f) else Color.Transparent,
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(
                                            text = AIModel.prettifiedDisplayName(model.modelID),
                                            style = MaterialTheme.typography.bodyLarge,
                                            color = Color.White,
                                            fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                                            maxLines = 1,
                                            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        // "Vision" badge.
                                        Surface(
                                            shape = RoundedCornerShape(6.dp),
                                            color = Color(0xFF9B7D00).copy(alpha = 0.3f),
                                        ) {
                                            Text(
                                                text = "Vision",
                                                style = MaterialTheme.typography.labelSmall,
                                                color = Color(0xFFFFD84D),
                                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                            )
                                        }
                                    }
                                    Text(
                                        text = model.modelID,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = Color.White.copy(alpha = 0.45f),
                                        maxLines = 1,
                                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                                    )
                                }
                                if (isSelected) {
                                    Box(
                                        modifier = Modifier
                                            .size(24.dp)
                                            .clip(CircleShape)
                                            .background(Color(0xFF6AA9FF)),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        Icon(
                                            imageVector = Icons.Outlined.Check,
                                            contentDescription = null,
                                            tint = Color.White,
                                            modifier = Modifier.size(14.dp),
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            TextButton(
                onClick = onDismiss,
                modifier = Modifier
                    .align(Alignment.End)
                    .padding(top = 8.dp),
            ) {
                Text("Cancel", color = Color.White.copy(alpha = 0.6f))
            }
        }
    }
}

// ---------------------------------------------------------------------
// Follow-up composer
// ---------------------------------------------------------------------

@Composable
private fun FollowUpComposer(
    draft: String,
    enabled: Boolean,
    sending: Boolean,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onOpenSettings: () -> Unit,
    missingKey: Boolean,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(24.dp),
        color = Color.White.copy(alpha = 0.1f),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 6.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = draft,
                onValueChange = onDraftChange,
                modifier = Modifier.weight(1f),
                enabled = enabled,
                placeholder = {
                    Text(
                        text = if (missingKey) {
                            "Add an API key in Settings to ask follow-ups."
                        } else {
                            "Ask about this photo…"
                        },
                        color = Color.White.copy(alpha = 0.45f),
                    )
                },
                colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    cursorColor = Color(0xFF6AA9FF),
                    focusedBorderColor = Color.Transparent,
                    unfocusedBorderColor = Color.Transparent,
                ),
                maxLines = 4,
                shape = RoundedCornerShape(20.dp),
            )
            Surface(
                onClick = { if (missingKey) onOpenSettings() else if (enabled) onSend() },
                shape = CircleShape,
                color = if (enabled || missingKey) Color(0xFF6AA9FF) else Color.White.copy(alpha = 0.15f),
                modifier = Modifier.padding(start = 4.dp).size(42.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    if (sending) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = Color.White,
                        )
                    } else {
                        Icon(
                            imageVector = if (missingKey) Icons.Outlined.ChevronRight
                            else Icons.AutoMirrored.Outlined.Send,
                            contentDescription = if (missingKey) "Open Settings" else "Send",
                            tint = if (enabled || missingKey) Color.Black else Color.White.copy(alpha = 0.4f),
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------
// Turn bubble
// ---------------------------------------------------------------------

@Composable
private fun TurnBubble(turn: VisionViewModel.Turn) {
    val isUser = turn.role == VisionViewModel.Turn.Role.User
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
    ) {
        Surface(
            color = if (isUser) Color(0xFF6AA9FF) else Color.White.copy(alpha = 0.12f),
            contentColor = if (isUser) Color.Black else Color.White,
            shape = RoundedCornerShape(
                topStart = 16.dp,
                topEnd = 16.dp,
                bottomStart = if (isUser) 16.dp else 4.dp,
                bottomEnd = if (isUser) 4.dp else 16.dp,
            ),
            modifier = Modifier.widthIn(max = 300.dp),
        ) {
            if (turn.isError) {
                Text(
                    text = turn.text,
                    style = MaterialTheme.typography.bodyMedium,
                    color = Color(0xFFFF6B6B),
                    modifier = Modifier.padding(12.dp),
                )
            } else if (isUser) {
                Text(
                    text = turn.text,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(12.dp),
                )
            } else {
                Box(modifier = Modifier.padding(12.dp)) {
                    MarkdownText(markdown = turn.text)
                }
            }
        }
    }
}

// ---------------------------------------------------------------------
// Chrome components
// ---------------------------------------------------------------------

@Composable
private fun ChromeCircleButton(
    onClick: () -> Unit,
    contentDescription: String,
    icon: ImageVector,
    onSurface: Boolean = false,
) {
    Surface(
        modifier = Modifier.size(44.dp),
        shape = CircleShape,
        color = if (onSurface) Color.White.copy(alpha = 0.15f) else Color.Black.copy(alpha = 0.45f),
        onClick = onClick,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                imageVector = icon,
                contentDescription = contentDescription,
                tint = Color.White,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

@Composable
private fun ShutterButton(enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier.size(72.dp),
        contentAlignment = Alignment.Center,
    ) {
        // Outer ring.
        Surface(
            modifier = Modifier.fillMaxSize(),
            shape = CircleShape,
            color = Color.Transparent,
            border = BorderStroke(3.dp, Color.White.copy(alpha = if (enabled) 1f else 0.5f)),
            onClick = { if (enabled) onClick() },
        ) {}
        // Inner circle.
        Surface(
            modifier = Modifier
                .size(if (enabled) 58.dp else 54.dp),
            shape = CircleShape,
            color = Color.White.copy(alpha = if (enabled) 1f else 0.5f),
            onClick = { if (enabled) onClick() },
        ) {}
    }
}

@Composable
private fun ModelPill(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onSurface: Boolean = false,
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(22.dp),
        color = if (onSurface) Color.White.copy(alpha = 0.15f) else Color.Black.copy(alpha = 0.45f),
        onClick = onClick,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.Visibility,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(16.dp),
            )
            Text(
                text = label,
                color = Color.White,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 180.dp),
            )
            Icon(
                imageVector = Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.7f),
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun ErrorPill(
    message: String,
    modifier: Modifier = Modifier,
    onDismiss: (() -> Unit)? = null,
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(12.dp),
        color = Color(0xFFFF6B6B).copy(alpha = 0.15f),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = message,
                style = MaterialTheme.typography.bodyMedium,
                color = Color(0xFFFF6B6B),
                modifier = Modifier.weight(1f),
            )
            if (onDismiss != null) {
                TextButton(onClick = onDismiss) {
                    Text("Dismiss", color = Color(0xFFFF6B6B).copy(alpha = 0.8f))
                }
            }
        }
    }
}

// ---------------------------------------------------------------------
// CameraX capture glue
// ---------------------------------------------------------------------

private suspend fun awaitCameraProvider(context: Context): ProcessCameraProvider =
    suspendCancellableCoroutine { cont ->
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener(
            {
                try {
                    cont.resume(future.get())
                } catch (e: Throwable) {
                    cont.resumeWithException(e)
                }
            },
            ContextCompat.getMainExecutor(context),
        )
    }

/**
 * Capture a still to a real [File] in the cache dir, then hand a
 * FileProvider URI back to the [onResult] callback.
 *
 * We pass a real [File] path (not a content URI) because
 * `ImageCapture.takePicture` needs an actual filesystem destination.
 * We then wrap that file in a FileProvider URI so the rest of the
 * pipeline can stay uniform.
 */
private fun captureToCache(
    context: Context,
    imageCapture: ImageCapture,
    onResult: (Uri) -> Unit,
    onError: (Throwable) -> Unit,
) {
    val file = createCameraOutputFile(context)
    val output = ImageCapture.OutputFileOptions.Builder(file).build()
    val executor: Executor = ContextCompat.getMainExecutor(context)
    imageCapture.takePicture(
        output,
        executor,
        object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                onResult(fileToUri(context, file))
            }
            override fun onError(exception: ImageCaptureException) {
                onError(exception)
            }
        },
    )
}

private fun createCameraOutputFile(context: Context): File {
    val dir = File(context.cacheDir, "camera").apply { mkdirs() }
    val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
    return File(dir, "vision_$timestamp.jpg")
}

private fun fileToUri(context: Context, file: File): Uri =
    FileProvider.getUriForFile(
        context,
        "${context.packageName}.fileprovider",
        file,
    )

/**
 * Read a content URI into bytes and forward to the view-model.
 * Wires the selected [VisionMode] into the prompt.
 */
private fun onImagePicked(
    context: Context,
    viewModel: VisionViewModel,
    uri: Uri,
    mode: VisionMode,
) {
    val resolver = context.contentResolver
    val mime = resolver.getType(uri) ?: "image/jpeg"
    if (!mime.startsWith("image/")) return
    viewModel.viewModelScope.launch {
        val bytes = VisionViewModel.readBytes(resolver, uri) ?: return@launch
        withContext(Dispatchers.Main) {
            viewModel.onImageReady(bytes, mime, mode)
        }
    }
}
