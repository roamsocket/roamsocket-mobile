package app.roamsocket.android

import android.app.Application
import app.roamsocket.android.data.EncryptedPrefsSecretStore
import app.roamsocket.android.data.UserSettings
import app.roamsocket.core.providers.HTTPClient
import app.roamsocket.core.providers.OkHttpHTTPClient
import app.roamsocket.core.providers.ProviderRegistry
import app.roamsocket.core.storage.SecretStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

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
     * Process-wide scope for long-lived collectors (chat history
     * mirror, NSD discovery, code session persistence, …). Use
     * `viewModelScope` from `androidx.lifecycle` for per-screen work.
     */
    val appScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /**
     * Persisted coding sessions (Code home list). Same DataStore
     * single-blob strategy as the chat history wrapper. Populated by
     * the Session screen when a session starts / updates.
     */
    val codeSessionRepository: app.roamsocket.core.code.CodeSessionRepository =
        app.roamsocket.android.data.DataStoreCodeSessionRepository(application, flowScope = appScope)

    /** Resolve a chat client for the given [providerId], or null if unsupported. */
    fun chatClientFor(providerId: app.roamsocket.core.providers.ProviderId) =
        ProviderRegistry.client(providerId, httpClient)
}
