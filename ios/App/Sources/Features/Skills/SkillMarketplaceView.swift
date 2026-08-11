import SwiftUI
import AnyProvCore

/// Browse marketplace skill listings (official + user-added marketplaces)
/// alongside skills already synced from the user's skills repo.
///
/// Marketplace skills with `instructions` can be installed directly: the
/// listing is mapped into a `Skill` and pushed to the desktop via
/// `skill_upsert`, which commits it to the user's skills git repo.
struct SkillMarketplaceView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var marketplace = MarketplaceStore.shared

    @State private var installingSkillIDs: Set<String> = []
    @State private var installError: String?
    @State private var installingPluginID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if marketplace.skills.isEmpty && marketplace.plugins.isEmpty && state.skillManager.installedSkills.isEmpty {
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
                                Text("Install a skill to push it to your skills repo via the paired desktop. Requires an active server connection.")
                            }
                        }

                        if !marketplace.plugins.isEmpty {
                            Section {
                                ForEach(marketplace.plugins) { plugin in
                                    pluginRow(plugin)
                                }
                            } header: {
                                Text("Plugins")
                            } footer: {
                                Text("Plugins install all their skills at once.")
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

    private func isInstalled(_ skillId: String) -> Bool {
        state.skillManager.installedSkills.contains { $0.id == skillId }
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
            HStack {
                if isInstalled(skill.id) {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                } else {
                    Button {
                        Task { await installSkill(skill) }
                    } label: {
                        if installingSkillIDs.contains(skill.id) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Install", systemImage: "arrow.down.circle")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .disabled(installingSkillIDs.contains(skill.id))
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func pluginRow(_ plugin: MarketplacePlugin) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "shippingbox")
                    .foregroundStyle(Theme.accent)
                Text(plugin.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if plugin.featured == true {
                    Text("Featured")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.2), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
            }
            if let desc = plugin.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            HStack {
                let skillIds = plugin.skillIds ?? []
                let available = skillIds.compactMap { id in
                    marketplace.skills.first { $0.id == id }
                }
                let allInstalled = !available.isEmpty && available.allSatisfy { isInstalled($0.id) }
                Text("\(skillIds.count) skill\(skillIds.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if available.isEmpty {
                    Text("No skills")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                } else if allInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                } else {
                    Button {
                        Task { await installPlugin(plugin) }
                    } label: {
                        if installingPluginID == plugin.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Install all", systemImage: "arrow.down.circle")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .disabled(installingPluginID == plugin.id)
                }
            }
            .padding(.top, 2)
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

    // MARK: - Install actions

    private func installSkill(_ listing: MarketplaceSkillListing) async {
        installingSkillIDs.insert(listing.id)
        installError = nil
        defer { installingSkillIDs.remove(listing.id) }

        let skill = listing.toSkill()
        do {
            try await state.skillsMCPClient.upsertSkill(skill, over: state.serverClient)
            state.skillManager.apply(skills: state.skillsMCPClient.cachedSkills)
        } catch {
            installError = error.localizedDescription
        }
    }

    private func installPlugin(_ plugin: MarketplacePlugin) async {
        installingPluginID = plugin.id
        installError = nil
        defer { installingPluginID = nil }

        let skillIds = plugin.skillIds ?? []
        for id in skillIds {
            guard let listing = marketplace.skills.first(where: { $0.id == id }) else { continue }
            guard !isInstalled(listing.id) else { continue }
            let skill = listing.toSkill()
            do {
                try await state.skillsMCPClient.upsertSkill(skill, over: state.serverClient)
            } catch {
                installError = error.localizedDescription
                break
            }
        }
        state.skillManager.apply(skills: state.skillsMCPClient.cachedSkills)
    }
}
