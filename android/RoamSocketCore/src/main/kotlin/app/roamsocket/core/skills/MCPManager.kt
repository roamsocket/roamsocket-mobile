/*
 * In-memory cache of configured MCP servers.
 *
 * Mirrors `ios/AnyProvCore/.../Skills/MCPManager.swift`. Same shape as
 * [SkillManager] but for the MCP server table the agent loop uses to
 * expose tool calls.
 */
package app.roamsocket.core.skills

import app.roamsocket.core.protocol.MCPServer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Persistence hook. App module plugs a DataStore-backed impl in. */
public interface MCPStore {
    public suspend fun load(): List<MCPServer>
    public suspend fun save(servers: List<MCPServer>)
}

public class MCPManager(
    private val store: MCPStore,
) {
    private val _servers = MutableStateFlow<List<MCPServer>>(emptyList())
    public val servers: StateFlow<List<MCPServer>> = _servers.asStateFlow()

    public val enabledServers: List<MCPServer> get() = _servers.value.filter { it.isEnabled }

    public suspend fun apply(servers: List<MCPServer>) {
        val current = _servers.value
        val enabledIds = current.asSequence().filter { it.isEnabled }.map { it.id }.toSet()
        val merged = servers.map { server ->
            if (enabledIds.contains(server.id)) server else server.copy(isEnabled = false)
        }
        _servers.value = merged
        store.save(merged)
    }

    public suspend fun toggleServer(serverId: String) {
        val current = _servers.value
        val next = current.map { if (it.id == serverId) it.copy(isEnabled = !it.isEnabled) else it }
        _servers.value = next
        store.save(next)
    }

    public suspend fun load(): List<MCPServer> {
        val restored = store.load()
        _servers.value = restored
        return restored
    }
}
