package app.roamsocket.android.ui.study

import android.Manifest
import android.content.Context
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
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import app.roamsocket.android.ui.theme.Palette
import app.roamsocket.core.providers.AIModel
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// ---------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------

/**
 * Full-screen Study scan flow: camera → vision analysis → editable flashcards
 * → save into the session deck.
 *
 * Ports [StudyScanView] from iOS `StudyScanView.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StudyScanScreen(
    onClose: () -> Unit,
    viewModel: StudyViewModel = viewModel(
        key = "StudyScanScreen",
        factory = StudyViewModel.Factory,
    ),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    // Capture ViewModel instance before lambdas so the compiler resolves
    // instance method calls (readBitmap, beginCapture, etc.) rather than
    // the composable viewModel() function in scope.
    val vm = viewModel
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current

    var showModelPicker by remember { mutableStateOf(false) }
    var showDiscardConfirm by remember { mutableStateOf(false) }
    var showExitConfirm by remember { mutableStateOf(false) }
    var cameraError by remember { mutableStateOf<String?>(null) }
    var hasCameraPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED,
        )
    }
    val cameraPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted -> hasCameraPermission = granted }

    val galleryLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            GlobalScope.launch(Dispatchers.IO) {
                val bitmap = vm.readBitmap(context, uri)
                if (bitmap != null) {
                    vm.beginCapture()
                    vm.analyze(bitmap)
                }
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        when (state.phase) {
            StudyViewModel.Phase.REVIEW -> reviewView(
                state = state,
                onClose = {
                    if (state.hasUnsavedCards) showExitConfirm = true
                    else onClose()
                },
                onSaveAll = viewModel::saveAllCards,
                onNextQuestions = {
                    if (state.hasUnsavedCards) showDiscardConfirm = true
                    else viewModel.startNextScan()
                },
            )
            StudyViewModel.Phase.FAILED -> failedView(
                state = state,
                onClose = onClose,
                onRetry = viewModel::retryAnalysis,
                onRetake = viewModel::startNextScan,
            )
            else -> cameraChrome(
                vm = vm,
                state = state,
                hasCameraPermission = hasCameraPermission,
                onRequestCameraPermission = { cameraPermissionLauncher.launch(Manifest.permission.CAMERA) },
                onClose = {
                    if (state.phase == StudyViewModel.Phase.REVIEW && state.hasUnsavedCards) {
                        showExitConfirm = true
                    } else {
                        onClose()
                    }
                },
                onSelectModel = { showModelPicker = true },
                onCapture = {
                    if (state.selectedModel == null) {
                        showModelPicker = true
                        return@cameraChrome
                    }
                    viewModel.beginCapture()
                },
                onPickGallery = {
                    galleryLauncher.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                    )
                },
                onCaptureResult = { bitmap ->
                    viewModel.analyze(bitmap)
                },
                onCaptureError = { cameraError = it },
            )
        }
    }

    // Model picker sheet.
    if (showModelPicker) {
        StudyModelPickerSheet(
            models = state.visionModels,
            selected = state.selectedModel,
            onSelect = { picked ->
                viewModel.selectModel(picked)
                showModelPicker = false
            },
            onDismiss = { showModelPicker = false },
        )
    }

    // Camera error.
    if (cameraError != null) {
        AlertDialog(
            onDismissRequest = { cameraError = null },
            title = { Text("Camera") },
            text = { Text(cameraError!!) },
            confirmButton = { TextButton(onClick = { cameraError = null }) { Text("OK") } },
        )
    }

    // Discard unsaved cards (next questions).
    if (showDiscardConfirm) {
        val suffix = if (state.unsavedCount == 1) "" else "s"
        AlertDialog(
            onDismissRequest = { showDiscardConfirm = false },
            title = { Text("Discard unsaved cards?") },
            text = { Text("You have ${state.unsavedCount} unsaved card$suffix. They won't be added to the deck.") },
            confirmButton = {
                TextButton(onClick = {
                    showDiscardConfirm = false
                    viewModel.startNextScan()
                }) { Text("Discard & scan next") }
            },
            dismissButton = {
                TextButton(onClick = { showDiscardConfirm = false }) { Text("Keep editing") }
            },
        )
    }

    // Discard unsaved cards (exit).
    if (showExitConfirm) {
        val suffix = if (state.unsavedCount == 1) "" else "s"
        AlertDialog(
            onDismissRequest = { showExitConfirm = false },
            title = { Text("Discard unsaved cards?") },
            text = { Text("You have ${state.unsavedCount} unsaved card$suffix. They won't be added to the deck.") },
            confirmButton = {
                TextButton(onClick = {
                    showExitConfirm = false
                    onClose()
                }) { Text("Discard & exit") }
            },
            dismissButton = {
                TextButton(onClick = { showExitConfirm = false }) { Text("Keep editing") }
            },
        )
    }
}

// ---------------------------------------------------------------------
// Camera chrome (live / capturing / analyzing)
// ---------------------------------------------------------------------

@Composable
private fun cameraChrome(
    vm: StudyViewModel,
    state: StudyViewModel.UiState,
    hasCameraPermission: Boolean,
    onRequestCameraPermission: () -> Unit,
    onClose: () -> Unit,
    onSelectModel: () -> Unit,
    onCapture: () -> Unit,
    onPickGallery: () -> Unit,
    onCaptureResult: (android.graphics.Bitmap) -> Unit,
    onCaptureError: (String) -> Unit,
) {
    val context = LocalContext.current
    var imageCapture by remember { mutableStateOf<ImageCapture?>(null) }
    val isThinking = state.phase == StudyViewModel.Phase.CAPTURING || state.phase == StudyViewModel.Phase.ANALYZING

    Column(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .padding(horizontal = 16.dp),
    ) {
        // Top bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ChromeCircleButton(
                onClick = onClose,
                contentDescription = "Close Study",
                icon = Icons.Outlined.Close,
            )
            Spacer(modifier = Modifier.weight(1f))
            ModelPill(
                label = state.selectedModel?.let { AIModel.prettifiedDisplayName(it.modelID) } ?: "Choose model",
                onClick = onSelectModel,
            )
        }

        // Camera area
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            contentAlignment = Alignment.Center,
        ) {
            if (hasCameraPermission) {
                StudyCameraPreview(
                    onImageCaptureReady = { imageCapture = it },
                )
            } else {
                CameraPermissionPrompt(onRequest = onRequestCameraPermission)
            }

            // Analyzing overlay
            if (isThinking) {
                AnalyzingOverlay(
                    capturedImage = state.capturedImage,
                )
            }
        }

        // Bottom controls
        Column(
            modifier = Modifier
                .navigationBarsPadding()
                .padding(vertical = 16.dp),
        ) {
            if (state.selectedModel == null && state.visionModels.isEmpty()) {
                Text(
                    text = "Add a Vision model to scan",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.7f),
                    modifier = Modifier
                        .padding(horizontal = 14.dp, vertical = 10.dp)
                        .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(20.dp)),
                )
                Spacer(modifier = Modifier.height(12.dp))
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ChromeCircleButton(
                    onClick = onPickGallery,
                    contentDescription = "Pick from gallery",
                    icon = Icons.Outlined.PhotoLibrary,
                )

                ShutterButton(
                    enabled = state.selectedModel != null && !isThinking,
                    onClick = {
                        if (state.selectedModel == null) {
                            onSelectModel()
                            return@ShutterButton
                        }
                        val capture = imageCapture
                        if (capture != null) {
                            onCapture()
                            studyCaptureToCache(context, capture) { uri ->
                                GlobalScope.launch(Dispatchers.IO) {
                                    val bitmap = vm.readBitmap(context, uri)
                                    if (bitmap != null) {
                                        onCaptureResult(bitmap)
                                    } else {
                                        onCaptureError("Could not decode the captured photo.")
                                    }
                                }
                            }
                        }
                    },
                )

                ChromeCircleButton(
                    onClick = onSelectModel,
                    contentDescription = "Pick vision model",
                    icon = Icons.Outlined.CameraAlt,
                )
            }
        }
    }
}

@Composable
private fun AnalyzingOverlay(capturedImage: android.graphics.Bitmap?) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.35f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.padding(24.dp),
        ) {
            capturedImage?.let { bmp ->
                Image(
                    bitmap = bmp.asImageBitmap(),
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxWidth(0.55f)
                        .height(280.dp)
                        .background(
                            Color.Black.copy(alpha = 0.6f),
                            RoundedCornerShape(14.dp),
                        ),
                )
                Spacer(modifier = Modifier.height(16.dp))
            }

            CircularProgressIndicator(
                color = Palette.Accent,
                modifier = Modifier.size(36.dp),
            )
            Spacer(modifier = Modifier.height(16.dp))
            Text(
                text = "Reading questions\u2026",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                color = Color.White,
            )
        }
    }
}

// ---------------------------------------------------------------------
// Review view (flashcard cards)
// ---------------------------------------------------------------------

@Composable
private fun reviewView(
    state: StudyViewModel.UiState,
    onClose: () -> Unit,
    onSaveAll: () -> Unit,
    onNextQuestions: () -> Unit,
) {
    val listState = rememberLazyListState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Palette.Background)
            .imePadding(),
    ) {
        // Header
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(
                onClick = onClose,
                shape = CircleShape,
                color = Palette.SurfaceElevated,
                modifier = Modifier.size(40.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Outlined.Close,
                        contentDescription = "Close Study",
                        tint = Palette.TextPrimary,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }

            Spacer(modifier = Modifier.width(10.dp))

            Column {
                Text(
                    text = "Question cards",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.TextPrimary,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Outlined.CheckCircle,
                        contentDescription = null,
                        tint = Palette.Accent,
                        modifier = Modifier.size(12.dp),
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(
                        text = if (state.cards.isEmpty()) "No questions found"
                        else "${state.savedCount} of ${state.cards.size} saved",
                        style = MaterialTheme.typography.bodySmall,
                        color = Palette.TextSecondary,
                    )
                }
            }

            Spacer(modifier = Modifier.weight(1f))

            if (state.savedCount == state.cards.size && state.cards.isNotEmpty()) {
                Surface(
                    shape = RoundedCornerShape(20.dp),
                    color = Palette.Accent.copy(alpha = 0.14f),
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.CheckCircle,
                            contentDescription = null,
                            tint = Palette.Accent,
                            modifier = Modifier.size(12.dp),
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            text = "All saved",
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.SemiBold,
                            color = Palette.Accent,
                        )
                    }
                }
            }
        }

        // Cards list
        if (state.cards.isEmpty()) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                    modifier = Modifier.padding(32.dp),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.CameraAlt,
                        contentDescription = null,
                        tint = Palette.TextTertiary,
                        modifier = Modifier.size(40.dp),
                    )
                    Text(
                        text = "No questions found",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = Palette.TextPrimary,
                    )
                    Text(
                        text = "The model couldn't pick out any questions from this photo. Try a closer shot, or scan the next page.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = Palette.TextSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(14.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    horizontal = 16.dp, vertical = 12.dp,
                ),
            ) {
                itemsIndexed(state.cards) { index, card ->
                    val saveState = when {
                        card.isSaved && card.isDirty -> StudyCardSaveState.DIRTY
                        card.isSaved -> StudyCardSaveState.SAVED
                        else -> StudyCardSaveState.UNSAVED
                    }
                    FlashcardCard(
                        index = index + 1,
                        question = card.question,
                        answer = card.answer,
                        reasoning = card.reasoning,
                        saveState = saveState,
                        showSaveButton = true,
                        onQuestionChange = { },
                        onAnswerChange = { },
                        onReasonChange = { },
                        onSave = { },
                    )
                }
            }
        }

        // Bottom bar
        HorizontalDivider(color = Palette.Divider.copy(alpha = 0.7f))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // Save all button
            Surface(
                onClick = onSaveAll,
                enabled = state.canSaveAll,
                shape = RoundedCornerShape(14.dp),
                color = if (state.canSaveAll) Palette.Accent else Palette.SurfaceElevated,
                modifier = Modifier.weight(1f),
            ) {
                Row(
                    modifier = Modifier.padding(vertical = 14.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.CheckCircle,
                        contentDescription = null,
                        tint = if (state.canSaveAll) Palette.OnAccent else Palette.TextSecondary,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = if (state.hasUnsavedCards) "Save all" else "All saved",
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = if (state.canSaveAll) Palette.OnAccent else Palette.TextSecondary,
                    )
                    if (state.hasUnsavedCards) {
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = "${state.unsavedCount}",
                            style = MaterialTheme.typography.labelMedium,
                            color = Palette.OnAccent.copy(alpha = 0.7f),
                        )
                    }
                }
            }

            // Next questions button
            Surface(
                onClick = onNextQuestions,
                shape = RoundedCornerShape(14.dp),
                color = Palette.SurfaceElevated,
                border = BorderStroke(1.dp, Palette.Divider.copy(alpha = 0.8f)),
                modifier = Modifier.weight(1f),
            ) {
                Row(
                    modifier = Modifier.padding(vertical = 14.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "Next questions",
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = Palette.TextPrimary,
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Icon(
                        imageVector = Icons.Outlined.CameraAlt,
                        contentDescription = null,
                        tint = Palette.TextPrimary,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
        }
    }
}

// ---------------------------------------------------------------------
// Failed view
// ---------------------------------------------------------------------

@Composable
private fun failedView(
    state: StudyViewModel.UiState,
    onClose: () -> Unit,
    onRetry: () -> Unit,
    onRetake: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .padding(horizontal = 16.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ChromeCircleButton(
                onClick = onClose,
                contentDescription = "Close Study",
                icon = Icons.Outlined.Close,
            )
        }

        Box(
            modifier = Modifier.weight(1f),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.padding(32.dp),
            ) {
                Icon(
                    imageVector = Icons.Outlined.Close,
                    contentDescription = null,
                    tint = Palette.Danger,
                    modifier = Modifier.size(48.dp),
                )
                Text(
                    text = "Analysis failed",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.TextPrimary,
                )
                Text(
                    text = state.errorMessage ?: "Unknown error",
                    style = MaterialTheme.typography.bodyMedium,
                    color = Palette.TextSecondary,
                    textAlign = TextAlign.Center,
                )
                Spacer(modifier = Modifier.height(8.dp))
                Button(onClick = onRetry) { Text("Retry") }
                TextButton(onClick = onRetake) { Text("Retake") }
            }
        }
    }
}

// ---------------------------------------------------------------------
// Shared UI primitives
// ---------------------------------------------------------------------

@Composable
private fun ChromeCircleButton(
    onClick: () -> Unit,
    contentDescription: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
) {
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = Color.Black.copy(alpha = 0.45f),
        modifier = Modifier.size(44.dp),
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
        Surface(
            modifier = Modifier.fillMaxSize(),
            shape = CircleShape,
            color = Color.Transparent,
            border = BorderStroke(3.dp, Color.White.copy(alpha = if (enabled) 1f else 0.5f)),
            onClick = { if (enabled) onClick() },
        ) {}
        Surface(
            modifier = Modifier.size(if (enabled) 58.dp else 54.dp),
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
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(22.dp),
        color = Color.Black.copy(alpha = 0.45f),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.CameraAlt,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = label,
                style = MaterialTheme.typography.bodySmall,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
            )
        }
    }
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
                imageVector = Icons.Outlined.CameraAlt,
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
                text = "Study needs the camera to capture photos for analysis.",
                style = MaterialTheme.typography.bodyMedium,
                color = Color.White.copy(alpha = 0.8f),
                textAlign = TextAlign.Center,
            )
            Button(onClick = onRequest) { Text("Allow camera") }
        }
    }
}

// ---------------------------------------------------------------------
// CameraX preview (Study-scoped)
// ---------------------------------------------------------------------

@Composable
private fun StudyCameraPreview(
    onImageCaptureReady: (ImageCapture) -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val previewView = remember { PreviewView(context) }

    LaunchedEffect(previewView) {
        val provider = studyAwaitCameraProvider(context)
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

    androidx.compose.ui.viewinterop.AndroidView(
        factory = { previewView },
        modifier = Modifier
            .fillMaxSize()
            .padding(10.dp),
    )
}

// ---------------------------------------------------------------------
// CameraX capture glue
// ---------------------------------------------------------------------

private suspend fun studyAwaitCameraProvider(context: Context): ProcessCameraProvider =
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

private fun studyCaptureToCache(
    context: Context,
    imageCapture: ImageCapture,
    onResult: (Uri) -> Unit,
) {
    val dir = File(context.cacheDir, "camera").apply { mkdirs() }
    val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
    val file = File(dir, "study_$timestamp.jpg")
    val output = ImageCapture.OutputFileOptions.Builder(file).build()
    val executor: Executor = ContextCompat.getMainExecutor(context)
    imageCapture.takePicture(
        output,
        executor,
        object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(_0: ImageCapture.OutputFileResults) {
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
                onResult(uri)
            }
            override fun onError(exception: ImageCaptureException) {
                Log.e("StudyScanScreen", "capture failed", exception)
            }
        },
    )
}
