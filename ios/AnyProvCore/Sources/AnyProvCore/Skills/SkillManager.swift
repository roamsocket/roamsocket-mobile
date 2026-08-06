import Foundation

/// Manages skills sourced from a git repo on the user's GitHub account.
///
/// All git operations live on the desktop (which has `git` in PATH and a real
/// filesystem). This class is the iOS view: it tracks the local cache from
/// the last `skills_sync` push, exposes `enabledSkills` for the agent loop,
/// and forwards edit requests over the WebSocket via `SkillsMCPClient`.
///
/// The repo URL + branch are configured on the desktop side (Settings) and
/// replicated to the app via the WebSocket `skills_sync` payload. Nothing is
/// bundled in the app.
public final class SkillManager: ObservableObject, @unchecked Sendable {
    @Published public private(set) var installedSkills: [Skill] = []
    @Published public var isLoading = false
    @Published public var loadError: String?

    private let installedKey = "installedSkills.v1"

    public init() {
        loadInstalledSkills()
    }

    /// Apply a fresh list from the desktop (also called from the WebSocket
    /// sync handler).
    public func apply(skills: [Skill]) {
        // Preserve local `isEnabled` for skills that haven't been deleted.
        let enabledIds = Set(installedSkills.filter { $0.isEnabled }.map(\.id))
        installedSkills = skills.map { skill in
            var copy = skill
            copy.isEnabled = enabledIds.contains(skill.id)
            return copy
        }
        saveInstalledSkills()
    }

    public func toggleSkill(_ skillId: String) {
        if let idx = installedSkills.firstIndex(where: { $0.id == skillId }) {
            installedSkills[idx].isEnabled.toggle()
            saveInstalledSkills()
        }
    }

    public var enabledSkills: [Skill] {
        installedSkills.filter { $0.isEnabled }
    }

    // MARK: - Persistence

    private func loadInstalledSkills() {
        guard let data = UserDefaults.standard.data(forKey: installedKey),
              let skills = try? JSONDecoder().decode([Skill].self, from: data)
        else { return }
        installedSkills = skills
    }

    private func saveInstalledSkills() {
        if let data = try? JSONEncoder().encode(installedSkills) {
            UserDefaults.standard.set(data, forKey: installedKey)
        }
    }
}
