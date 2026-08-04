import SwiftUI
import MobileAICore

/// View for managing installed skills.
struct InstalledSkillsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showMarketplace = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if state.skillManager.installedSkills.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 48))
                            .foregroundStyle(Theme.textTertiary)
                        Text("No skills installed")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Text("Install skills from the marketplace to enhance your AI coding experience")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Browse Marketplace") {
                            showMarketplace = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(state.skillManager.installedSkills) { skill in
                            InstalledSkillRow(skill: skill) {
                                state.skillManager.toggleSkill(skill.id)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let skill = state.skillManager.installedSkills[index]
                                state.skillManager.uninstall(skill.id)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Installed Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMarketplace = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showMarketplace) {
                SkillMarketplaceView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct InstalledSkillRow: View {
    let skill: Skill
    let onToggle: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: skill.category.icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 6))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(skill.description)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { skill.isEnabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}
