import SwiftUI
import MobileAICore

/// Lists skills synced from the user's configured skills repo. No bundled
/// marketplace — every skill here was added either on the desktop side or
/// directly in the repo, and synced over the WebSocket.
struct SkillMarketplaceView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if state.skillManager.installedSkills.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tray")
                            .font(.system(size: 48))
                            .foregroundStyle(Theme.textTertiary)
                        Text("No skills yet")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Text("Skills from your configured skills repo will appear here. Add one to the repo or ask the desktop to sync.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(state.skillManager.installedSkills) { skill in
                                SkillCard(skill: skill) {
                                    state.skillManager.toggleSkill(skill.id)
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        Task {
                                            try? await state.skillsMCPClient.deleteSkill(
                                                id: skill.id,
                                                over: state.serverClient
                                            )
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            Text("Skills")
                        } footer: {
                            Text("Synced from your skills repo. Toggle to include in coding sessions.")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            try? await state.skillsMCPClient.requestSkillsSync(over: state.serverClient)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct SkillCard: View {
    let skill: Skill
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accent)
                Text(skill.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { skill.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                .labelsHidden()
            }
            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}
