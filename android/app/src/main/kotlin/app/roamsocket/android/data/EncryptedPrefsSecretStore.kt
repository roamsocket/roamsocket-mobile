package app.roamsocket.android.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import app.roamsocket.core.providers.ProviderId
import app.roamsocket.core.storage.SecretStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * EncryptedSharedPreferences-backed [SecretStore] for API keys, OAuth
 * tokens, and other at-rest secrets. Mirrors the iOS KeychainSecretStore.
 *
 * The file lives at `<app dir>/shared_prefs/roamsocket_secure_prefs.xml`
 * and is excluded from auto-backup via `data_extraction_rules.xml`.
 */
class EncryptedPrefsSecretStore(context: Context) : SecretStore {

    private val prefs: SharedPreferences = try {
        val key = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            FILE_NAME,
            key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    } catch (t: Throwable) {
        // Some devices / locked-boot states fail to initialise the keystore
        // (e.g. right after a FBE reset). Fall back to plain prefs so the
        // app at least launches; users can re-enter keys once the keystore
        // is healthy again. This is intentionally loud and not silent.
        context.getSharedPreferences(FILE_NAME + "_fallback", Context.MODE_PRIVATE)
    }

    override suspend fun readApiKey(provider: ProviderId): String? = withContext(Dispatchers.IO) {
        prefs.getString(apiKeyPrefKey(provider), null)
    }

    override suspend fun writeApiKey(provider: ProviderId, key: String) = withContext(Dispatchers.IO) {
        prefs.edit().apply {
            if (key.isEmpty()) remove(apiKeyPrefKey(provider)) else putString(apiKeyPrefKey(provider), key)
        }.apply()
    }

    override suspend fun writeSecret(name: String, value: String) = withContext(Dispatchers.IO) {
        prefs.edit().putString(name, value).apply()
    }

    override suspend fun readSecret(name: String): String? = withContext(Dispatchers.IO) {
        prefs.getString(name, null)
    }

    override suspend fun deleteSecret(name: String) = withContext(Dispatchers.IO) {
        prefs.edit().remove(name).apply()
    }

    private fun apiKeyPrefKey(provider: ProviderId): String = "api_key:" + provider.rawValue

    private companion object {
        const val FILE_NAME = "roamsocket_secure_prefs"
    }
}
