/*
 * DataStore wrapper that holds the local cache for installed skills
 * and configured MCP servers. The cache is the same shape as
 * `ios/AnyProvCore` but persisted to a Preferences DataStore instead
 * of `UserDefaults` (which Android doesn't have).
 *
 * Both keys are owned by the persistence interfaces in
 * [app.roamsocket.core.skills] (SkillStore, MCPStore); this file
 * implements those interfaces and exposes the DataStore handle.
 */
package app.roamsocket.android.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.roamsocket.core.protocol.MCPServer
import app.roamsocket.core.protocol.Skill
import app.roamsocket.core.skills.MCPStore
import app.roamsocket.core.skills.SkillStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

private val Context.skillsMCPDataStore: DataStore<Preferences> by preferencesDataStore(
    name = "roamsocket_skills_mcp",
)

/** The single DataStore used by the skills + MCP managers. The
 *  managers are decoupled from the storage handle so unit tests can
 *  inject a fake. */
fun Context.skillsMCPStore(): DataStore<Preferences> = skillsMCPDataStore

private val SKILLS_KEY = stringPreferencesKey("skillsMCP.installedSkills.v1")
private val MCP_KEY = stringPreferencesKey("skillsMCP.configuredMCPServers.v1")

private val JSON: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}

/** DataStore-backed [SkillStore]. */
public class DataStoreSkillStore(
    private val dataStore: DataStore<Preferences>,
) : SkillStore {
    override suspend fun load(): List<Skill> {
        val raw = dataStore.data.map { it[SKILLS_KEY] }.first() ?: return emptyList()
        return runCatching {
            JSON.decodeFromString(ListSerializer(Skill.serializer()), raw)
        }.getOrDefault(emptyList())
    }

    override suspend fun save(skills: List<Skill>) {
        val raw = JSON.encodeToString(ListSerializer(Skill.serializer()), skills)
        dataStore.edit { it[SKILLS_KEY] = raw }
    }
}

/** DataStore-backed [MCPStore]. */
public class DataStoreMCPStore(
    private val dataStore: DataStore<Preferences>,
) : MCPStore {
    override suspend fun load(): List<MCPServer> {
        val raw = dataStore.data.map { it[MCP_KEY] }.first() ?: return emptyList()
        return runCatching {
            JSON.decodeFromString(ListSerializer(MCPServer.serializer()), raw)
        }.getOrDefault(emptyList())
    }

    override suspend fun save(servers: List<MCPServer>) {
        val raw = JSON.encodeToString(ListSerializer(MCPServer.serializer()), servers)
        dataStore.edit { it[MCP_KEY] = raw }
    }
}
