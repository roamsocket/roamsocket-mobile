package app.roamsocket.android

import android.app.Application
import app.roamsocket.android.data.EncryptedPrefsSecretStore
import app.roamsocket.android.data.UserSettings
import app.roamsocket.core.providers.HTTPClient
import app.roamsocket.core.providers.OkHttpHTTPClient
import app.roamsocket.core.providers.ProviderRegistry
import app.roamsocket.core.storage.SecretStore

/**
 * Manual DI container — held by the Application and read by ViewModels.
 * Switch to Hilt/Koin later if the wiring gets too verbose.
 */
class AppContainer(application: Application) {

    val secretStore: SecretStore = EncryptedPrefsSecretStore(application)
    val userSettings: UserSettings = UserSettings(application)
    val httpClient: HTTPClient = OkHttpHTTPClient()

    /** Resolve a chat client for the given [providerId], or null if unsupported. */
    fun chatClientFor(providerId: app.roamsocket.core.providers.ProviderId) =
        ProviderRegistry.client(providerId, httpClient)
}
