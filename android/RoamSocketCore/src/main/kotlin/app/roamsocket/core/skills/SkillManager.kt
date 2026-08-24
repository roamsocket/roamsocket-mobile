/*
 * In-memory cache of installed skills.
 *
 * Mirrors `ios/AnyProvCore/.../Skills/SkillManager.swift`. The desktop
 * owns the canonical state (it manages the skills git repo on the
 * user's GitHub); the app just keeps a local cache for offline view
 * and to power the toggle switches immediately without a round-trip.
 *
 * The actual sync wire-up lives in [SkillsMCPClient]; this class is
 * the cold cache + presentation layer. Persistence is handled by the
 * app module's DataStore wrapper (see
 * `app.roamsocket.android.data.SkillsMCPDataStore`) — this class stays
 * a pure-JVM type so it remains unit-testable without an emulator.
 */
package app.roamsocket.core.skills

import app.roamsocket.core.protocol.Skill
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Persistence hook. The app module plugs a DataStore-backed
 * implementation in; tests can plug in a fake.
 */
public interface SkillStore {
    public suspend fun load(): List<Skill>
    public suspend fun save(skills: List<Skill>)
}

public class SkillManager(
    private val store: SkillStore,
) {
    private val _installedSkills = MutableStateFlow<List<Skill>>(emptyList())
    public val installedSkills: StateFlow<List<Skill>> = _installedSkills.asStateFlow()

    public val enabledSkills: List<Skill> get() = _installedSkills.value.filter { it.isEnabled }

    /** Replace the cache with a fresh list from the desktop. Preserves
     *  local `isEnabled` for skills that still exist by id. */
    public suspend fun apply(skills: List<Skill>) {
        val current = _installedSkills.value
        val enabledIds = current.asSequence().filter { it.isEnabled }.map { it.id }.toSet()
        val merged = skills.map { skill ->
            if (enabledIds.contains(skill.id)) skill else skill.copy(isEnabled = false)
        }
        _installedSkills.value = merged
        store.save(merged)
    }

    /** Optimistic local toggle; the desktop will see the same value on
     *  the next `skills_sync` reply. */
    public suspend fun toggleSkill(skillId: String) {
        val current = _installedSkills.value
        val next = current.map { if (it.id == skillId) it.copy(isEnabled = !it.isEnabled) else it }
        _installedSkills.value = next
        store.save(next)
    }

    /** Bootstrap from disk; called once at app start. */
    public suspend fun load(): List<Skill> {
        val restored = store.load()
        _installedSkills.value = restored
        return restored
    }
}
