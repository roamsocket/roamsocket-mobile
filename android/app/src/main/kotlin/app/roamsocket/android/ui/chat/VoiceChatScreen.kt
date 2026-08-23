package app.roamsocket.android.ui.chat

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.MicOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import app.roamsocket.android.AppContainer
import app.roamsocket.android.RoamSocketApplication
import app.roamsocket.android.ui.LocalAppContainer

/**
 * PR #77: full-screen voice-chat UI. Mirrors the iOS
 * `ios/.../VoiceChatView` in spirit (centered mic button, status
 * headline, live caption) at a smaller scope:
 *
 *  * No voice settings sheet (Android's `TextToSpeech` engine ships
 *    with one default voice; iOS personal-voice / HiFi is not
 *    available).
 *  * No provider-settings quick link — the user can change model via
 *    the regular chat composer and re-enter voice mode.
 *  * Reply text is read aloud verbatim (no per-language voice picker).
 *
 * Wired from [ChatScreen]'s mic button. The mic icon takes the user
 * here; the close button returns to the chat composer with the
 * transcribed turn already sent.
 */
@Composable
fun VoiceChatScreen(
    onClose: () -> Unit,
    /** Called when a committed transcript turn is ready to send. */
    onSendTurn: (String) -> Unit,
    /**
     * Called whenever the latest assistant reply is ready, so the
     * voice layer can speak it aloud. Wired from the chat screen
     * which knows the model streaming state.
     */
    onObserveReply: ((String) -> Unit) -> Unit,
) {
    val container = LocalAppContainer.current
    val viewModel: VoiceChatViewModel = viewModel(
        key = "VoiceChatScreen",
        factory = voiceChatViewModelFactory(container),
    )
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current

    var hasMicPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED,
        )
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
    ) { granted ->
        hasMicPermission = granted
        if (granted) {
            viewModel.startListening()
        } else {
            viewModel.presentError("Microphone permission was denied.")
        }
    }

    // Wire the voice view-model to the host callbacks. Done in a
    // LaunchedEffect keyed on the callbacks so the wiring survives
    // recomposition but updates if the host swaps the lambda.
    LaunchedEffect(viewModel) {
        viewModel.pendingSendCallback = onSendTurn
        onObserveReply { reply -> viewModel.onAssistantReply(reply) }
    }

    // Auto-start listening as soon as permission is granted.
    LaunchedEffect(hasMicPermission) {
        if (hasMicPermission && state.phase == VoiceChatViewModel.Phase.IDLE) {
            viewModel.startListening()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(horizontal = 24.dp, vertical = 24.dp),
    ) {
        // Top bar — close button only (mirrors iOS VoiceChatView's
        // close X in the top-left). Model picker / settings live in
        // the regular chat composer so the voice sheet stays focused
        // on the loop.
        Box(modifier = Modifier.fillMaxWidth()) {
            IconButton(
                onClick = {
                    viewModel.stopListening()
                    onClose()
                },
                modifier = Modifier.align(Alignment.CenterStart),
            ) {
                Icon(
                    imageVector = Icons.Outlined.Close,
                    contentDescription = "Close voice chat",
                    tint = MaterialTheme.colorScheme.onSurface,
                )
            }
        }

        Spacer(modifier = Modifier.size(32.dp))

        // Headline — mirrors iOS `statusHeadline` so users see the
        // same copy across platforms.
        Text(
            text = state.statusHeadline,
            style = MaterialTheme.typography.headlineSmall.copy(
                fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.size(16.dp))

        // Live caption — iOS shows the partial transcript in a
        // monospaced grey block. We mirror that as a body-text row.
        Text(
            text = if (state.liveCaption.isNotEmpty()) {
                "“${state.liveCaption}”"
            } else {
                ""
            },
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.weight(1f))

        // The mic button: large circular surface, accent fill, with
        // a different glyph + color when actively listening. iOS uses
        // a pulsating mic; we use a stateful icon swap for now.
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 24.dp),
        ) {
            IconButton(
                onClick = {
                    when {
                        !hasMicPermission -> {
                            permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                        }
                        state.phase == VoiceChatViewModel.Phase.LISTENING -> {
                            viewModel.stopListening()
                            viewModel.commitTurn()
                        }
                        state.phase == VoiceChatViewModel.Phase.ERROR -> {
                            viewModel.resetToIdle()
                            viewModel.startListening()
                        }
                        else -> viewModel.startListening()
                    }
                },
                modifier = Modifier
                    .size(96.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primary),
            ) {
                Icon(
                    imageVector = if (state.phase == VoiceChatViewModel.Phase.LISTENING) {
                        Icons.Outlined.MicOff
                    } else {
                        Icons.Outlined.Mic
                    },
                    contentDescription = if (state.phase == VoiceChatViewModel.Phase.LISTENING) {
                        "Stop listening"
                    } else {
                        "Start listening"
                    },
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(40.dp),
                )
            }
        }

        // Bottom hint — gives the user something to read while the
        // status headline is empty. Mirrors the iOS "Tap to start"
        // affordance.
        Text(
            text = when (state.phase) {
                VoiceChatViewModel.Phase.IDLE -> "Tap the mic to start chatting."
                VoiceChatViewModel.Phase.LISTENING -> "Tap again when you're done."
                VoiceChatViewModel.Phase.THINKING -> "Hold tight — the model is thinking."
                VoiceChatViewModel.Phase.SPEAKING -> "Listening for your reply…"
                VoiceChatViewModel.Phase.ERROR -> "Tap the mic to try again."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 16.dp),
        )
    }
}

/**
 * Compose-friendly factory that injects the [AppContainer] into the
 * [VoiceChatViewModel]. Mirrors the per-feature `factoryFor(...)`
 * helpers used by the rest of the chat surface.
 */
private fun voiceChatViewModelFactory(container: AppContainer): ViewModelProvider.Factory =
    object : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            val app = container.applicationContext as RoamSocketApplication
            return VoiceChatViewModel(app) as T
        }
    }
