package app.roamsocket.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.roamsocket.android.ui.LocalAppContainer
import app.roamsocket.android.ui.RootView
import app.roamsocket.android.ui.theme.RoamSocketTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = (application as RoamSocketApplication).container
        setContent {
            // Live-collect the persisted AppAppearance so flipping the
            // Settings → Appearance card recomposes the whole tree with
            // the right color scheme.
            val appearance by container.userSettings.appearance
                .collectAsStateWithLifecycle(initialValue = container.defaultAppearance)
            CompositionLocalProvider(LocalAppContainer provides container) {
                RoamSocketTheme(appearance = appearance) {
                    RootView()
                }
            }
        }
    }
}
