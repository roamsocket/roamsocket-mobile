import SwiftUI
import AnyProvCore

/// Browse marketplace skill listings (official + user-added marketplaces)
/// alongside skills already synced from the user's skills repo.
struct SkillMarketplaceView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var marketplace = MarketplaceStore.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if marketplace.skills.isEmpty && state.skillManager.installedSkills.isEmpty {
                    emptyState
                } else {
                    List {
                        if !marketplace.skills.isEmpty {
                            Section {
                                ForEach(marketplace.skills) { skill in
                                    marketplaceSkillRow(skill)
                                }
                            } header: {
                                Text("Marketplace")
                            } footer: {
                                Text("From enabled marketplace repos. Install full skill bodies via your skills repo or desktop.")
                            }
                        }

                        if !state.skillManager.installedSkills.isEmpty {
                            Section {
                                ForEach(state.skillManager.installedSkills) { skill in
                                    installedSkillRow(skill)
                                }
                            } header: {
                                Text("Installed (synced)")
                            } footer: {
                                Text("Synced from your skills repo. Toggle to include in coding sessions.")
                            }
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
                            await marketplace.refresh()
                            try? await state.skillsMCPClient.requestSkillsSync(over: state.serverClient)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                if marketplace.skills.isEmpty {
                    await marketplace.refresh()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("No skills yet")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Enable a marketplace in Settings → Marketplace, or sync a skills repo from the desktop.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func marketplaceSkillRow(_ skill: MarketplaceSkillListing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accent)
                Text(skill.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if skill.featured == true {
                    Text("Featured")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.2), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                if let src = skill.source {
                    Text(src.capitalized)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
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

    private func installedSkillRow(_ skill: Skill) -> some View {
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
                    set: { _ in state.skillManager.toggleSkill(skill.id) }
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
}
