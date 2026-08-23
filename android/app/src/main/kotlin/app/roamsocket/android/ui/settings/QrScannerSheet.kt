package app.roamsocket.android.ui.settings

import android.Manifest
import android.content.pm.PackageManager
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview as CameraPreview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import app.roamsocket.android.ui.theme.Palette
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import java.util.concurrent.Executors

/**
 * Camera-driven QR scanner composable. Mirrors the iOS
 * `PairQRScannerView` (`ios/.../Settings/PairQRScannerView.swift`).
 *
 * On a successful scan the raw payload is fed through
 * [parsePairPayload] and the result is delivered via [onScanned].
 * One scan only — the caller dismisses the sheet on receipt.
 *
 * Requires `android.permission.CAMERA`. The composable requests
 * the permission via `rememberLauncherForActivityResult`; on deny
 * it shows a clear error state instead of opening the camera.
 */
@Composable
fun QrScannerSheet(
    onDismiss: () -> Unit,
    onScanned: (PairPayload) -> Unit,
) {
    val context = LocalContext.current
    var permissionGranted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
    ) { granted -> permissionGranted = granted }

    LaunchedEffect(Unit) {
        if (!permissionGranted) permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    Surface(
        color = MaterialTheme.colorScheme.background,
        modifier = Modifier.fillMaxSize(),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Palette.Surface)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Spacer(Modifier.weight(1f))
                Text(
                    text = "Scan desktop QR",
                    color = Palette.TextPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.weight(1f))
                // Spacer to keep title centred.
                TextButton(onClick = {}, enabled = false) { Text("Cancel") }
            }
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black),
                contentAlignment = Alignment.Center,
            ) {
                if (permissionGranted) {
                    CameraPreviewArea(onScanned = onScanned)
                    QrReticleOverlay()
                    Text(
                        text = "Point at the QR shown in the desktop app",
                        color = Color.White.copy(alpha = 0.8f),
                        fontSize = 13.sp,
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(24.dp),
                    )
                } else {
                    PermissionDeniedState(
                        onRequestAgain = { permissionLauncher.launch(Manifest.permission.CAMERA) },
                    )
                }
            }
        }
    }
}

@Composable
private fun CameraPreviewArea(onScanned: (PairPayload) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val previewView = remember { PreviewView(context) }
    val executor = remember { Executors.newSingleThreadExecutor() }
    val barcodeScanner: BarcodeScanner = remember {
        BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build(),
        )
    }
    var done by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        onDispose {
            executor.shutdown()
            barcodeScanner.close()
        }
    }

    AndroidView(
        factory = { previewView },
        modifier = Modifier.fillMaxSize(),
        update = { view ->
            val providerFuture = ProcessCameraProvider.getInstance(view.context)
            providerFuture.addListener({
                val provider = providerFuture.get()
                val preview = CameraPreview.Builder().build().also {
                    it.setSurfaceProvider(view.surfaceProvider)
                }
                val analysis = ImageAnalysis.Builder()
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
                            .build(),
                    )
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                    .also { ia ->
                        ia.setAnalyzer(executor) { imageProxy ->
                            if (done) {
                                imageProxy.close()
                                return@setAnalyzer
                            }
                            val media = imageProxy.image
                            if (media == null) {
                                imageProxy.close()
                                return@setAnalyzer
                            }
                            barcodeScanner.process(
                                com.google.mlkit.vision.common.InputImage.fromMediaImage(
                                    media,
                                    imageProxy.imageInfo.rotationDegrees,
                                ),
                            )
                                .addOnSuccessListener { barcodes ->
                                    if (!done) {
                                        val raw = barcodes.firstOrNull { it.rawValue != null }?.rawValue
                                        if (raw != null) {
                                            val payload = parsePairPayload(raw)
                                            if (payload != null) {
                                                done = true
                                                onScanned(payload)
                                            }
                                        }
                                    }
                                }
                                .addOnCompleteListener { imageProxy.close() }
                        }
                    }
                try {
                    provider.unbindAll()
                    provider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        analysis,
                    )
                } catch (_: Throwable) {
                    // Camera not available (emulator without a camera, etc.)
                    // — fall through and the user sees a black preview.
                }
            }, androidx.core.content.ContextCompat.getMainExecutor(view.context))
        },
    )
}

@Composable
private fun QrReticleOverlay() {
    // Centre 60% reticle drawn as four L-shaped corners so the
    // preview stays visible.
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(48.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(240.dp, 240.dp)
                .background(Color.Transparent),
            contentAlignment = Alignment.Center,
        ) {
            // Subtle border to hint at the scan area.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Transparent),
            )
        }
    }
}

@Composable
private fun PermissionDeniedState(onRequestAgain: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.padding(24.dp),
    ) {
        Icon(
            imageVector = Icons.Outlined.QrCodeScanner,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(48.dp),
        )
        Text(
            text = "Camera permission needed to scan the desktop QR.",
            color = Color.White,
            fontSize = 14.sp,
        )
        TextButton(onClick = onRequestAgain) {
            Text("Grant camera access", color = Palette.Accent, fontWeight = FontWeight.SemiBold)
        }
    }
}
