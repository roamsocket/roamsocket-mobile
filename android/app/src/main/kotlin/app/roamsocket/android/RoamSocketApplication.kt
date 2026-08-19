package app.roamsocket.android

import android.app.Application

/**
 * App entry point. Keep this thin — feature wiring lives in MainActivity and
 * the per-feature ViewModels. Long-term this is where dependency-injection
 * (Hilt / Koin) bootstraps; for now we just hold a global AppState handle.
 */
class RoamSocketApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Reserved for future setup (DI graph, crash reporter, telemetry opt-in,
        // push registration, etc). See AGENTS.md for the iOS equivalent.
    }
}
