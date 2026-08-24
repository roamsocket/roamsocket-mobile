/*
 * Marketplace fetch + cache. Mirrors the iOS
 * `ios/AnyProvCore/.../Marketplace/MarketplaceStore.swift`.
 *
 * Responsibilities:
 *  * Hold a list of `MarketplaceSource`s (default + user-added).
 *  * Fetch each source's `catalog.json` over HTTPS and merge the
 *    results into a single in-memory `MarketplaceCatalog`.
 *  * Surface a hot `StateFlow` the UI can collect to redraw.
 *  * Expose helpers for the URL normaliser (owner/repo → raw GitHub).
 *
 * The actual HTTP fetch uses `OkHttpHTTPClient` from the providers
 * package so the marketplace reuses the same TLS / timeout knobs the
 * rest of the app uses.
 */
package app.roamsocket.core.marketplace

import app.roamsocket.core.providers.HTTPClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/**
 * In-memory marketplace state. Single instance lives in [AppContainer]
 * (Android) / the AppState (iOS); both clients reload on demand.
 */
public class MarketplaceStore(
    private val httpClient: HTTPClient,
    private val appScope: CoroutineScope,
    private val json: Json = DEFAULT_JSON,
) {
    private val mutex = Mutex()

    private val _state = MutableStateFlow(MarketplaceState.DEFAULT)
    public val state: StateFlow<MarketplaceState> = _state.asStateFlow()

    public val catalog: MarketplaceCatalog get() = _state.value.catalog
    public val sources: List<MarketplaceSource> get() = _state.value.sources

    /**
     * Force a fresh fetch from every enabled source. Merges by id /
     * hubID so later sources override earlier (user-added beats
     * official, etc.). Errors per source are stored in
     * [MarketplaceSource.lastError] and surfaced through [state].
     */
    public suspend fun refresh(): MarketplaceCatalog = withContext(Dispatchers.IO) {
        val current = mutex.withLock { _state.value }
        val now = System.currentTimeMillis()
        val updatedSources = current.sources.map { src ->
            if (!src.enabled) {
                src.copy(lastError = null)
            } else {
                runCatching { fetchCatalog(src.url) }
                    .fold(
                        onSuccess = { cat ->
                            src.copy(
                                lastFetchedAt = now,
                                lastError = null,
                                catalogName = cat.name,
                            )
                        },
                        onFailure = { e ->
                            src.copy(
                                lastFetchedAt = now,
                                lastError = e.message ?: e.javaClass.simpleName,
                            )
                        },
                    )
            }
        }

        // Refetched catalogs need their own pass so the merge sees the
        // updated error state. Run a second pass for any source that
        // returned successfully.
        val enabledCatalogs = updatedSources.mapNotNull { src ->
            if (src.enabled && src.lastError == null) {
                runCatching { fetchCatalog(src.url) }.getOrNull()
            } else null
        }
        val merged = mergeCatalogs(enabledCatalogs)
        val next = current.copy(sources = updatedSources, catalog = merged)
        mutex.withLock { _state.value = next }
        merged
    }

    /** Add a new marketplace source, normalising the URL. */
    public fun addSource(rawUrl: String, name: String? = null) {
        val url = normalizeUrl(rawUrl)
        if (!isValidUrl(url)) return
        val id = "user-${System.currentTimeMillis().toString(36)}"
        val src = MarketplaceSource(
            id = id,
            name = name?.takeIf { it.isNotBlank() } ?: url,
            url = url,
            enabled = true,
            isDefault = false,
        )
        _state.value = _state.value.copy(
            sources = _state.value.sources + src,
        )
    }

    public fun removeSource(id: String) {
        val current = _state.value
        if (current.sources.any { it.id == id && it.isDefault }) return
        _state.value = current.copy(
            sources = current.sources.filterNot { it.id == id },
        )
    }

    public fun setSourceEnabled(id: String, enabled: Boolean) {
        val current = _state.value
        _state.value = current.copy(
            sources = current.sources.map { if (it.id == id) it.copy(enabled = enabled) else it },
        )
    }

    private suspend fun fetchCatalog(url: String): MarketplaceCatalog {
        val request = okhttp3.Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            .get()
            .build()
        val response = httpClient.data(request)
        return json.decodeFromString(MarketplaceCatalog.serializer(), response.body)
    }

    public companion object {
        public val DEFAULT_JSON: Json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

        /** Combine N catalogs into one; later wins on id collisions. */
        public fun mergeCatalogs(catalogs: List<MarketplaceCatalog>): MarketplaceCatalog {
            if (catalogs.isEmpty()) return MarketplaceCatalog.EMPTY
            val connectors = LinkedHashMap<String, MarketplaceConnector>()
            val skills = LinkedHashMap<String, MarketplaceSkillListing>()
            val plugins = LinkedHashMap<String, MarketplacePlugin>()
            val cats = LinkedHashMap<String, MarketplacePluginCategory>()
            val metal = LinkedHashMap<String, MarketplaceMetalModel>()
            var name: String? = null
            var description: String? = null
            var updatedAt: String? = null

            for (c in catalogs) {
                if (c.name != null) name = c.name
                if (c.description != null) description = c.description
                if (c.updatedAt != null) updatedAt = c.updatedAt
                c.connectors.forEach { connectors[it.id] = it }
                c.skills.forEach { skills[it.id] = it }
                c.plugins.forEach { plugins[it.id] = it }
                c.pluginCategories.forEach { cats[it.id] = it }
                c.metalModels.forEach { metal[it.hubID] = it }
            }

            return MarketplaceCatalog(
                schemaVersion = MARKETPLACE_SCHEMA_VERSION,
                updatedAt = updatedAt,
                name = name ?: "Merged marketplace",
                description = description,
                connectors = connectors.values.sortedBy { it.name.lowercase() },
                skills = skills.values.sortedBy { it.name.lowercase() },
                plugins = plugins.values.sortedBy { it.name.lowercase() },
                pluginCategories = cats.values.toList(),
                metalModels = metal.values.toList(),
            )
        }

        /** Accept bare URLs, `owner/repo`, or GitHub blob/tree links and
         *  return a raw.githubusercontent.com URL. */
        public fun normalizeUrl(input: String): String {
            val u = input.trim()
            // https://github.com/<o>/<r>/blob/<b>/<path>
            val blobMatch = GITHUB_BLOB.find(u)
            if (blobMatch != null) {
                val (o, r, b, p) = blobMatch.destructured
                return "https://raw.githubusercontent.com/$o/$r/$b/$p"
            }
            // https://github.com/<o>/<r>/tree/<b>/<rest?>
            val treeMatch = GITHUB_TREE.find(u)
            if (treeMatch != null) {
                val (o, r, b, rest) = treeMatch.destructured
                val clean = rest.trim('/')
                val file = when {
                    clean.isEmpty() -> "catalog.json"
                    clean.endsWith(".json") -> clean
                    else -> "$clean/catalog.json"
                }
                return "https://raw.githubusercontent.com/$o/$r/$b/$file"
            }
            // bare owner/repo
            if (BARE_REPO.matches(u)) {
                return "https://raw.githubusercontent.com/$u/main/catalog.json"
            }
            return u
        }

        public fun isValidUrl(url: String): Boolean {
            val s = url.lowercase()
            return s.startsWith("https://") || s.startsWith("http://")
        }

        private val GITHUB_BLOB = Regex(
            "^https?://github\\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$",
            RegexOption.IGNORE_CASE,
        )
        private val GITHUB_TREE = Regex(
            "^https?://github\\.com/([^/]+)/([^/]+)/tree/([^/]+)/?(.*)$",
            RegexOption.IGNORE_CASE,
        )
        private val BARE_REPO = Regex("^[\\w.-]+/[\\w.-]+$")
    }
}
