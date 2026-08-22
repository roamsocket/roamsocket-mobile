package app.roamsocket.android.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
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
 * The primary file lives at `<app dir>/shared_prefs/roamsocket_secure_prefs.xml`
 * and is excluded from auto-backup via `data_extraction_rules.xml`.
 *
 * When the AndroidKeyStore is unhealthy (e.g. right after a FBE reset, or
 * on a device with a broken keystore), the encrypted prefs file fails to
 * initialise. We fall back to a PLAINTEXT SharedPreferences file with the
 * explicit `unsafe_fallback` infix so it is unmistakable on disk. The
 * fallback file is also excluded from cloud-backup and device-transfer
 * (see `data_extraction_rules.xml`) — without that exclusion, the user's
 * API keys would sync to Google Drive in the clear.
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
        // Last-resort plaintext fallback. The filename and the warning are
        // both loud on purpose — anyone inspecting the app's data dir or
        // logcat should immediately see that secrets are stored unencrypted.
        // Users on a healthy device never hit this path; those who do need
        // to know their keys aren't protected until the keystore recovers.
        Log.e(
            TAG,
            "AndroidKeyStore unavailable (${t.javaClass.simpleName}: ${t.message}). " +
                "Falling back to UNENCRYPTED SharedPreferences at " +
                "'$UNSAFE_FALLBACK_FILE_NAME'. Stored secrets are not protected " +
                "at rest until the device keystore recovers. Re-enter keys in " +
                "Settings once the keystore is healthy.",
            t,
        )
        context.getSharedPreferences(UNSAFE_FALLBACK_FILE_NAME, Context.MODE_PRIVATE)
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
        const val TAG = "EncryptedPrefsSecretStore"
        const val FILE_NAME = "roamsocket_secure_prefs"
        const val UNSAFE_FALLBACK_FILE_NAME = "roamsocket_secure_prefs_unsafe_fallback"
    }
}
