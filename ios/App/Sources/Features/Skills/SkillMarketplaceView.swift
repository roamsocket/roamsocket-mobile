import SwiftUI
import MobileAICore

/// Marketplace view for browsing and installing skills.
struct SkillMarketplaceView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: SkillCategory?
    @State private var searchText = ""
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if state.skillManager.isLoading {
                    ProgressView("Loading skills...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = state.skillManager.loadError {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.textSecondary)
                        Button("Retry") {
                            Task { await state.skillManager.fetchMarketplace() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredSkills) { skill in
                                SkillCard(skill: skill) {
                                    state.skillManager.install(skill)
                                } onToggle: {
                                    state.skillManager.toggleSkill(skill.id)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Skills Marketplace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await state.skillManager.fetchMarketplace() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                if state.skillManager.marketplaceSkills.isEmpty {
                    await state.skillManager.fetchMarketplace()
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private var filteredSkills: [Skill] {
        var skills = state.skillManager.marketplaceSkills
        
        if let category = selectedCategory {
            skills = skills.filter { $0.category == category }
        }
        
        if !searchText.isEmpty {
            skills = skills.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return skills
    }
}

private struct SkillCard: View {
    @EnvironmentObject var state: AppState
    let skill: Skill
    let onInstall: () -> Void
    let onToggle: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: skill.category.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(skill.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        
                        if skill.source == .official {
                            Text("Official")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accent, in: Capsule())
                        }
                    }
                    
                    Text(skill.description)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                
                Spacer()
            }
            
            HStack {
                Text(skill.category.rawValue)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surfaceElevated, in: Capsule())
                
                Spacer()
                
                if isInstalled {
                    Toggle("", isOn: Binding(
                        get: { installedSkill?.isEnabled ?? false },
                        set: { _ in onToggle() }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                    .labelsHidden()
                } else {
                    Button("Install") {
                        onInstall()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private var installedSkill: Skill? {
        state.skillManager.installedSkills.first { $0.id == skill.id }
    }
    
    private var isInstalled: Bool {
        installedSkill != nil
    }
}
