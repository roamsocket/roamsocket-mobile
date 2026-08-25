package app.roamsocket.android

import android.app.Application
import app.roamsocket.android.data.AppAppearance
import app.roamsocket.android.data.DataStoreMCPStore
import app.roamsocket.android.data.DataStoreSkillStore
import app.roamsocket.android.data.EncryptedPrefsSecretStore
import app.roamsocket.android.data.UserSettings
import app.roamsocket.android.data.skillsMCPStore
import app.roamsocket.core.chats.ChatHistoryRepository
import app.roamsocket.core.marketplace.MarketplaceStore
import app.roamsocket.core.providers.HTTPClient
import app.roamsocket.core.providers.OkHttpHTTPClient
import app.roamsocket.core.providers.ProviderRegistry
import app.roamsocket.core.server.ServerClient
import app.roamsocket.core.skills.MCPManager
import app.roamsocket.core.skills.SkillManager
import app.roamsocket.core.skills.SkillsMCPClient
import app.roamsocket.core.storage.SecretStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Manual DI container — held by the Application and read by ViewModels.
 * Switch to Hilt/Koin later if the wiring gets too verbose.
 */
class AppContainer(application: Application) {

    val applicationContext: android.content.Context = application.applicationContext
    val secretStore: SecretStore = EncryptedPrefsSecretStore(application)
    val userSettings: UserSettings = UserSettings(application)
    val pairedServerStore: app.roamsocket.android.data.PairedServerStore =
        app.roamsocket.android.data.PairedServerStore(application)
    val httpClient: HTTPClient = OkHttpHTTPClient()

    /**
     * Default [AppAppearance] used as the [collectAsStateWithLifecycle]
     * seed before the DataStore's first read lands. Mirrors the
     * `UserSettings.appearance` default ([AppAppearance.System]).
     */
    val defaultAppearance: AppAppearance = AppAppearance.System

    /**
     * Process-wide scope for long-lived collectors (e.g. the chat
     * history mirror, NSD discovery, …). Use [viewModelScope] from
     * `androidx.lifecycle` for per-screen work.
     */
    val appScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /**
     * Persisted chat history (sidebar Recents + active chat). One global
     * instance; the in-memory repo it wraps is mutated by the
     * ChatViewModel and observed by the SidebarView.
     */
    val chatHistoryRepository: ChatHistoryRepository =
        app.roamsocket.android.data.DataStoreChatHistoryRepository(application, flowScope = appScope)

    /**
     * Persisted coding sessions (Code home list). Same DataStore
     * single-blob strategy as the chat history wrapper. Populated by
     * the Session screen when a session starts / updates.
     */
    val codeSessionRepository: app.roamsocket.core.code.CodeSessionRepository =
        app.roamsocket.android.data.DataStoreCodeSessionRepository(application, flowScope = appScope)

    /**
     * Persisted bookmarks/history/approval-granularity for the in-app
     * browser. Mirrors the iOS `BrowserStore`'s UserDefaults-backed
     * state so the Android app retains the same per-tab + per-page
     * memory across launches.
     */
    val browserPreferences: app.roamsocket.android.ui.browser.BrowserPreferences =
        app.roamsocket.android.ui.browser.BrowserPreferences(application, appScope = appScope)

    /**
     * The browser's main store. Held on the container so it survives
     * sidebar navigation (tabs, history, and the Ask-mode chat all
     * persist when the user leaves the Browser destination and
     * returns), matching the iOS pattern where `AppState` owns
     * `browserStore`.
     */
    val browserStore: app.roamsocket.android.ui.browser.BrowserStore by lazy {
        app.roamsocket.android.ui.browser.BrowserStore(this, browserPreferences, appScope)
    }

    /**
     * Saved chat artifacts — long assistant replies and code blocks
     * captured automatically during chat. Held on the container so the
     * `ChatViewModel` can write to it without owning the lifecycle,
     * mirroring iOS `AppState.artifactStore` in
     * `ios/App/Sources/App/AppState.swift`.
     */
    val artifactStore: app.roamsocket.android.ui.artifacts.ArtifactStore by lazy {
        app.roamsocket.android.ui.artifacts.ArtifactStore(application)
    }

    /**
     * Skills + MCP managers. Local cache for the skills / connectors
     * the desktop last pushed; flips to the desktop via
     * [skillsMCPClient] when the user is paired.
     */
    private val skillsMCPDataStore = application.skillsMCPStore()
    val skillManager: SkillManager = SkillManager(DataStoreSkillStore(skillsMCPDataStore))
    val mcpManager: MCPManager = MCPManager(DataStoreMCPStore(skillsMCPDataStore))
    val skillsMCPClient: SkillsMCPClient = SkillsMCPClient(ServerClient())
    val marketplaceStore: MarketplaceStore = MarketplaceStore(httpClient, appScope)

    /** Resolve a chat client for the given [providerId], or null if unsupported. */
    fun chatClientFor(providerId: app.roamsocket.core.providers.ProviderId) =
        ProviderRegistry.client(providerId, httpClient)

    /**
     * Cold-load the persisted skills + MCP caches. Safe to call
     * multiple times; [SkillManager.load] / [MCPManager.load] are
     * idempotent.
     */
    suspend fun preloadSkillsAndMCP() {
        skillManager.load()
        mcpManager.load()
    }
}
