package app.roamsocket.core.projects

import kotlinx.serialization.Serializable

/**
 * A user-created project that groups chats and carries private
 * instructions + memory. Mirrors the iOS `ProjectItem` in
 * `ios/App/Sources/Features/Chats/ChatHistory.swift` 1:1 (field
 * names, types, defaults).
 */
@Serializable
data class ProjectItem(
    val id: String,
    val name: String,
    val updatedAtMillis: Long,
    val instructions: String = "",
    val memory: String = "",
    val memoryUpdatedAtMillis: Long? = null,
)
