import Foundation

/// Manages the skill marketplace and installed skills.
public final class SkillManager: ObservableObject, @unchecked Sendable {
    @Published public private(set) var marketplaceSkills: [Skill] = []
    @Published public private(set) var installedSkills: [Skill] = []
    @Published public var isLoading = false
    @Published public var loadError: String?
    
    private let storageKey = "installedSkills.v1"
    private let marketplaceKey = "marketplaceSkills.v1"
    
    public init() {
        loadInstalledSkills()
        loadMarketplaceCache()
    }
    
    /// Fetch the latest skills from the MiniMax-AI/skills repository.
    public func fetchMarketplace() async {
        isLoading = true
        loadError = nil
        
        do {
            let skills = try await downloadSkillsFromGitHub()
            await MainActor.run {
                self.marketplaceSkills = skills
                self.isLoading = false
                self.saveMarketplaceCache()
            }
        } catch {
            await MainActor.run {
                self.loadError = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    /// Install a skill from the marketplace.
    public func install(_ skill: Skill) {
        guard !installedSkills.contains(where: { $0.id == skill.id }) else { return }
        var newSkill = skill
        newSkill.isEnabled = true
        installedSkills.append(newSkill)
        saveInstalledSkills()
    }
    
    /// Uninstall a skill.
    public func uninstall(_ skillId: String) {
        installedSkills.removeAll { $0.id == skillId }
        saveInstalledSkills()
    }
    
    /// Toggle a skill's enabled state.
    public func toggleSkill(_ skillId: String) {
        if let idx = installedSkills.firstIndex(where: { $0.id == skillId }) {
            installedSkills[idx].isEnabled.toggle()
            saveInstalledSkills()
        }
    }
    
    /// Get all enabled skills for injection into chat context.
    public var enabledSkills: [Skill] {
        installedSkills.filter { $0.isEnabled }
    }
    
    /// Build the system prompt addition for enabled skills.
    public func buildSkillsContext() -> String {
        let enabled = enabledSkills
        guard !enabled.isEmpty else { return "" }
        
        var context = "\n\n## Active Skills\n\n"
        context += "The following skills are active and should guide your approach:\n\n"
        
        for skill in enabled {
            context += "### \(skill.name)\n"
            context += skill.content
            context += "\n\n"
        }
        
        return context
    }
    
    // MARK: - Private
    
    private func loadInstalledSkills() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let skills = try? JSONDecoder().decode([Skill].self, from: data)
        else { return }
        installedSkills = skills
    }
    
    private func saveInstalledSkills() {
        if let data = try? JSONEncoder().encode(installedSkills) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func loadMarketplaceCache() {
        guard let data = UserDefaults.standard.data(forKey: marketplaceKey),
              let skills = try? JSONDecoder().decode([Skill].self, from: data)
        else { return }
        marketplaceSkills = skills
    }
    
    private func saveMarketplaceCache() {
        if let data = try? JSONEncoder().encode(marketplaceSkills) {
            UserDefaults.standard.set(data, forKey: marketplaceKey)
        }
    }
    
    private func downloadSkillsFromGitHub() async throws -> [Skill] {
        let repoURL = URL(string: "https://api.github.com/repos/MiniMax-AI/skills/contents/skills")!
        
        var request = URLRequest(url: repoURL)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "SkillManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch skills from GitHub"])
        }
        
        struct GitHubContent: Codable {
            let name: String
            let path: String
            let type: String
            let download_url: String?
        }
        
        let contents = try JSONDecoder().decode([GitHubContent].self, from: data)
        
        var skills: [Skill] = []
        
        for content in contents where content.type == "dir" {
            if let skill = try? await fetchSkillDetails(name: content.name, path: content.path) {
                skills.append(skill)
            }
        }
        
        return skills
    }
    
    private func fetchSkillDetails(name: String, path: String) async throws -> Skill {
        let skillFileURL = URL(string: "https://raw.githubusercontent.com/MiniMax-AI/skills/main/\(path)/SKILL.md")!
        
        let (data, _) = try await URLSession.shared.data(from: skillFileURL)
        let content = String(data: data, encoding: .utf8) ?? ""
        
        let description = extractDescription(from: content)
        let category = inferCategory(from: name)
        
        return Skill(
            id: name,
            name: formatSkillName(name),
            description: description,
            content: content,
            category: category,
            source: .official
        )
    }
    
    private func extractDescription(from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                return String(trimmed.prefix(200))
            }
        }
        return "Development skill for AI coding agents."
    }
    
    private func inferCategory(from name: String) -> SkillCategory {
        let lower = name.lowercased()
        if lower.contains("frontend") || lower.contains("react") || lower.contains("vue") {
            return .frontend
        } else if lower.contains("fullstack") || lower.contains("backend") {
            return .fullstack
        } else if lower.contains("ios") || lower.contains("android") || lower.contains("mobile") || lower.contains("flutter") || lower.contains("react-native") {
            return .mobile
        } else if lower.contains("devops") || lower.contains("docker") || lower.contains("kubernetes") {
            return .devops
        } else if lower.contains("database") || lower.contains("sql") {
            return .database
        } else if lower.contains("test") {
            return .testing
        } else if lower.contains("doc") {
            return .documentation
        } else if lower.contains("design") || lower.contains("ui") || lower.contains("ux") {
            return .design
        }
        return .other
    }
    
    private func formatSkillName(_ name: String) -> String {
        name.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
