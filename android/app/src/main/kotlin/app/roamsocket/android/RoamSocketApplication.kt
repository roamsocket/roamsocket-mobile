package app.roamsocket.android

import android.app.Application
import kotlinx.coroutines.launch

/**
 * App entry point. Keep this thin — feature wiring lives in MainActivity and
 * the per-feature ViewModels. Long-term this is where dependency-injection
 * (Hilt / Koin) bootstraps; for now we just hold a global AppState handle.
 */
class RoamSocketApplication : Application() {

    /** DI graph. Lazy so the keystore / DataStore are only touched on first use. */
    val container: AppContainer by lazy { AppContainer(this) }

    companion object {
        lateinit var instance: RoamSocketApplication
            private set
    }

    override fun onCreate() {
        instance = this
        super.onCreate()
        // PR #76: prune any incognito chats whose countdown elapsed while
        // the app was killed. Runs on the process-scoped appScope so the
        // DataStore write completes even if the UI hasn't mounted yet.
        container.appScope.launch {
            container.chatHistoryRepository.pruneExpiredIncognito()
        }
        // Skills + MCP local caches: warm the StateFlows so the
        // sidebar / Settings panels render instantly on first frame
        // (the manager is otherwise cold until a screen reads it).
        container.appScope.launch {
            container.preloadSkillsAndMCP()
        }
        // Reserved for future setup (DI graph, crash reporter, telemetry opt-in,
        // push registration, etc). See AGENTS.md for the iOS equivalent.
    }
}
