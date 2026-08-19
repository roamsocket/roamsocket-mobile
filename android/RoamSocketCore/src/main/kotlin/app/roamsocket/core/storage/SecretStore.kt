/*
 * Cross-platform secret store contract. Implementations live in the app
 * module (EncryptedSharedPreferences on Android, mirroring the iOS
 * KeychainSecretStore). The contract intentionally is async-friendly so
 * platform-specific backends can do IO without blocking the caller.
 */
package app.roamsocket.core.storage

import app.roamsocket.core.providers.ProviderId

public interface SecretStore {
    /** Read the API key for [provider], or null if not set. */
    public suspend fun readApiKey(provider: ProviderId): String?

    /** Persist [key] for [provider]. Empty value deletes the entry. */
    public suspend fun writeApiKey(provider: ProviderId, key: String)

    /** Persist an arbitrary secret under [name]. */
    public suspend fun writeSecret(name: String, value: String)

    /** Read an arbitrary secret. */
    public suspend fun readSecret(name: String): String?

    /** Remove an arbitrary secret. */
    public suspend fun deleteSecret(name: String)
}
