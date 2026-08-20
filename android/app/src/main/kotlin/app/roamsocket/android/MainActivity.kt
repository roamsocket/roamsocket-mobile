package app.roamsocket.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.CompositionLocalProvider
import app.roamsocket.android.ui.LocalAppContainer
import app.roamsocket.android.ui.RootView
import app.roamsocket.android.ui.theme.RoamSocketTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = (application as RoamSocketApplication).container
        setContent {
            CompositionLocalProvider(LocalAppContainer provides container) {
                RoamSocketTheme {
                    RootView()
                }
            }
        }
    }
}
