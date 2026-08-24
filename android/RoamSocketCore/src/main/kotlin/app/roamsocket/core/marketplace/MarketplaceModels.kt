/*
 * Wire-level shapes for the marketplace. Mirrors the Swift
 * `ios/AnyProvCore/.../Marketplace/MarketplaceModels.swift` and the
 * desktop `desktop-server/src/marketplace/types.ts`.
 *
 * The marketplace is a JSON catalog (default: roamsocket-official) that
 * lists connectors, skills, plugins, and on-device Metal models. The
 * schema is intentionally small so external repos can publish their own
 * catalog.json and users can add them as additional sources.
 */
package app.roamsocket.core.marketplace

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Bump when the catalog JSON shape changes incompatibly. */
public const val MARKETPLACE_SCHEMA_VERSION: Int = 1

/** Default official RoamSocket marketplace catalog URL. */
public const val DEFAULT_MARKETPLACE_URL: String =
    "https://raw.githubusercontent.com/roamsocket/roamsocket-marketplace/main/catalog.json"

public const val DEFAULT_MARKETPLACE_SOURCE_ID: String = "roamsocket-official"

@Serializable
public data class MarketplaceConnector(
    val id: String,
    val name: String,
    val description: String? = null,
    val icon: String? = null,
    val available: Boolean? = true,
    val category: String? = null,
) {
    public val isAvailable: Boolean get() = available ?: true
}

@Serializable
public data class MarketplaceSkillListing(
    val id: String,
    val name: String,
    val description: String,
    val category: String? = null,
    val author: String? = null,
    val source: String? = null,
    val featured: Boolean? = null,
    val instructions: String? = null,
) {
    /** Full skill body — `instructions` if present, otherwise a minimal
     *  markdown scaffold so the skill is at least useful in the agent. */
    public val skillContent: String
        get() {
            val body = instructions?.trim().orEmpty()
            return if (body.isNotEmpty()) body else "# $name\n\n$description\n"
        }
}

@Serializable
public data class MarketplacePlugin(
    val id: String,
    val name: String,
    val description: String? = null,
    val category: String? = null,
    val skillIds: List<String>? = null,
    val featured: Boolean? = null,
)

@Serializable
public data class MarketplacePluginCategory(
    val id: String,
    val label: String,
)

@Serializable
public data class MarketplaceMetalModel(
    val hubID: String,
    val displayName: String,
    val approxSize: String? = null,
    val blurb: String? = null,
    val tags: List<String>? = null,
    val platforms: List<String>? = null,
) {
    public fun supports(platform: String): Boolean {
        val ps = platforms ?: return true
        if (ps.isEmpty()) return true
        return ps.any { it.equals(platform, ignoreCase = true) }
    }
}

@Serializable
public data class MarketplaceCatalog(
    val schemaVersion: Int = MARKETPLACE_SCHEMA_VERSION,
    val updatedAt: String? = null,
    val name: String? = null,
    val description: String? = null,
    val connectors: List<MarketplaceConnector> = emptyList(),
    val skills: List<MarketplaceSkillListing> = emptyList(),
    val plugins: List<MarketplacePlugin> = emptyList(),
    val pluginCategories: List<MarketplacePluginCategory> = emptyList(),
    val metalModels: List<MarketplaceMetalModel> = emptyList(),
) {
    public companion object {
        public val EMPTY: MarketplaceCatalog = MarketplaceCatalog()
    }
}

/** A configured marketplace source (official default + user-added). */
@Serializable
public data class MarketplaceSource(
    val id: String,
    val name: String,
    val url: String,
    val enabled: Boolean = true,
    val isDefault: Boolean = false,
    val lastFetchedAt: Long? = null,
    val lastError: String? = null,
    val catalogName: String? = null,
) {
    public companion object {
        public fun makeDefault(
            url: String = DEFAULT_MARKETPLACE_URL,
        ): MarketplaceSource = MarketplaceSource(
            id = DEFAULT_MARKETPLACE_SOURCE_ID,
            name = "RoamSocket Official",
            url = url,
            enabled = url.isNotEmpty(),
            isDefault = true,
        )
    }
}

/** Top-level wrapper sent over the wire to consumers that want the
 *  catalog + the configured sources in one payload. */
@Serializable
public data class MarketplaceState(
    val sources: List<MarketplaceSource> = listOf(MarketplaceSource.makeDefault()),
    val catalog: MarketplaceCatalog = MarketplaceCatalog.EMPTY,
) {
    public companion object {
        public val DEFAULT: MarketplaceState = MarketplaceState()
    }
}

@Serializable
public data class SkillCategoryHint(
    val id: String,
    val label: String,
) {
    public companion object {
        /** Fixed ordering used by the marketplace + installed-skills UI. */
        public val ALL: List<SkillCategoryHint> = listOf(
            SkillCategoryHint("frontend", "Frontend"),
            SkillCategoryHint("fullstack", "Full Stack"),
            SkillCategoryHint("mobile", "Mobile"),
            SkillCategoryHint("devops", "DevOps"),
            SkillCategoryHint("database", "Database"),
            SkillCategoryHint("testing", "Testing"),
            SkillCategoryHint("documentation", "Documentation"),
            SkillCategoryHint("design", "Design"),
            SkillCategoryHint("other", "Other"),
        )
    }
}
