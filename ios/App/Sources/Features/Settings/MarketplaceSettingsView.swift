import SwiftUI
import AnyProvCore

/// Manage marketplace sources: official RoamSocket catalog + user-added GitHub repos.
struct MarketplaceSettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MarketplaceStore.shared

    @State private var showAdd = false
    @State private var addName = ""
    @State private var addURL = ""
    @State private var actionError: String?
    @State private var actionMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Marketplaces control connectors, skill listings, plugins, and recommended Metal models. Add any public catalog.json (see docs in the official marketplace repo).")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Theme.surface)
                }

                Section("Sources") {
                    ForEach(store.sources) { src in
                        sourceRow(src)
                    }
                    .onDelete(perform: deleteUserSources)

                    Button {
                        addName = ""
                        addURL = ""
                        showAdd = true
                    } label: {
                        Label("Add marketplace", systemImage: "plus.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                    .listRowBackground(Theme.surface)
                }

                Section("Catalog") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(store.usingBundledOnly ? "Bundled fallback" : "Live / cached")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.surface)

                    HStack {
                        Text("Connectors")
                        Spacer()
                        Text("\(store.connectors.count)")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.surface)

                    HStack {
                        Text("Skills")
                        Spacer()
                        Text("\(store.skills.count)")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.surface)

                    HStack {
                        Text("Plugins")
                        Spacer()
                        Text("\(store.plugins.count)")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.surface)

                    HStack {
                        Text("Metal models (iOS)")
                        Spacer()
                        Text("\(store.iosMetalModels.count)")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.surface)

                    if let t = store.lastMergedAt {
                        HStack {
                            Text("Last refresh")
                            Spacer()
                            Text(t.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .listRowBackground(Theme.surface)
                    }

                    Button {
                        Task {
                            await store.refresh()
                            if let err = store.lastRefreshError {
                                actionError = err
                                actionMessage = nil
                            } else {
                                actionMessage = "Marketplaces refreshed."
                                actionError = nil
                            }
                        }
                    } label: {
                        HStack {
                            if store.isRefreshing {
                                ProgressView()
                            }
                            Text(store.isRefreshing ? "Refreshing…" : "Refresh all")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .disabled(store.isRefreshing)
                    .listRowBackground(Theme.surface)
                }

                Section("How to make one") {
                    Text("Create a GitHub repo with marketplace/catalog.json, then paste the raw URL or owner/repo here. Full guide:")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Theme.surface)
                    Link(destination: URL(string: "https://github.com/roamsocket-ai/roamsocket-marketplace")!) {
                        Label("Marketplace repo on GitHub", systemImage: "book")
                    }
                    .listRowBackground(Theme.surface)
                }

                if let actionMessage {
                    Section {
                        Text(actionMessage)
                            .foregroundStyle(Theme.accent)
                            .listRowBackground(Theme.surface)
                    }
                }
                if let actionError {
                    Section {
                        Text(actionError)
                            .foregroundStyle(.red)
                            .listRowBackground(Theme.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Marketplace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAdd) {
                NavigationStack {
                    Form {
                        Section("Name (optional)") {
                            TextField("My team marketplace", text: $addName)
                        }
                        Section("Catalog URL") {
                            TextField("owner/repo or raw catalog.json URL", text: $addURL, axis: .vertical)
                                .lineLimit(2...4)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text("Accepts raw.githubusercontent.com URLs, github.com blob/tree links, or owner/repo.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .navigationTitle("Add marketplace")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAdd = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                do {
                                    _ = try store.addSource(name: addName.isEmpty ? nil : addName, url: addURL)
                                    showAdd = false
                                    Task {
                                        await store.refresh()
                                        actionMessage = "Marketplace added and refreshed."
                                        actionError = nil
                                    }
                                } catch {
                                    actionError = error.localizedDescription
                                }
                            }
                            .disabled(addURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ src: MarketplaceSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(src.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if src.isDefault {
                            Text("Default")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.2), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(src.url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { src.enabled },
                    set: { on in
                        try? store.setSourceEnabled(id: src.id, enabled: on)
                        Task { await store.refresh() }
                    }
                ))
                .labelsHidden()
                .tint(Theme.accent)
            }
            if let err = src.lastError, !err.isEmpty {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if let name = src.catalogName {
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.surface)
    }

    private func deleteUserSources(at offsets: IndexSet) {
        for index in offsets {
            let src = store.sources[index]
            guard !src.isDefault else { continue }
            try? store.removeSource(id: src.id)
        }
        Task { await store.refresh() }
    }
}
