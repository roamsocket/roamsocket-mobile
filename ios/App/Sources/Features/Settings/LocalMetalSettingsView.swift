import SwiftUI
import AnyProvCore

/// Download / delete / browse on-device Metal models for **chat only** (not coding).
///
/// Weights are never bundled — each model is downloaded on demand into
/// Application Support (from Hugging Face mlx-community / mlx-swift-lm registry).
struct LocalMetalSettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [LocalMetalCatalogEntry] = []
    @State private var downloaded: Set<String> = []
    @State private var loadedInMemory: Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var activeDownload: String?
    @State private var status = ""
    @State private var errorText: String?
    @State private var sizes: [String: Int64] = [:]
    @State private var runtimeReady = false
    @State private var search = ""
    @State private var familyFilter: String = "All"
    @State private var isRefreshingCatalog = false
    @State private var lastCatalogFetch: Date?

    private var families: [String] {
        let set = Set(entries.map(\.family))
        return ["All"] + set.sorted()
    }

    private var filtered: [LocalMetalCatalogEntry] {
        entries.filter { entry in
            let familyOK = familyFilter == "All" || entry.family == familyFilter
            let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchOK = q.isEmpty
                || entry.displayName.localizedCaseInsensitiveContains(q)
                || entry.hubID.localizedCaseInsensitiveContains(q)
            return familyOK && searchOK
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Run open models on this device with Metal (MLX). Chat only — coding sessions always use a cloud or desktop provider.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    Text("Models are not included in the app. Browse the catalog, download what you need, unload from memory, or delete to free space.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                    HStack {
                        Circle()
                            .fill(runtimeReady ? Color.green.opacity(0.9) : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(runtimeReady
                             ? "Metal runtime ready"
                             : "Metal runtime not ready — rebuild the app with MLX packages")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Section {
                    TextField("Search models", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Family", selection: $familyFilter) {
                        ForEach(families, id: \.self) { Text($0).tag($0) }
                    }
                    Button {
                        Task { await refreshCatalog(force: true) }
                    } label: {
                        HStack {
                            Text(isRefreshingCatalog ? "Refreshing catalog…" : "Refresh from Hugging Face")
                            Spacer()
                            if isRefreshingCatalog {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(isRefreshingCatalog)
                    if let lastCatalogFetch {
                        Text("Last pulled \(lastCatalogFetch.formatted(date: .abbreviated, time: .shortened)) · source: mlx-community + mlx-swift-lm registry")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                } header: {
                    Text("Catalog")
                } footer: {
                    Text("Live list from Hugging Face author mlx-community (text-generation), merged with models registered in mlx-swift-lm. Download links open the model page on huggingface.co.")
                }

                Section("Models (\(filtered.count))") {
                    if filtered.isEmpty {
                        Text("No models match. Try clearing search or refreshing the catalog.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(filtered) { entry in
                        modelRow(entry)
                    }
                }

                if !loadedInMemory.isEmpty {
                    Section {
                        Button("Unload all from memory") {
                            Task { await unloadAll() }
                        }
                    } footer: {
                        Text("Unload frees RAM but keeps downloads on disk. Delete removes weights entirely.")
                    }
                }

                Section {
                    Button("Refresh chat model list") {
                        Task {
                            await state.refreshModels()
                            status = "Chat model list updated."
                            await reloadStatus()
                        }
                    }
                    if !status.isEmpty {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.9))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("On-device (Metal)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                LocalMetalBootstrap.ensureRegistered()
                runtimeReady = LocalMetalRuntime.isReady
                await refreshCatalog(force: false)
                await reloadStatus()
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func modelRow(_ entry: LocalMetalCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.system(size: 16, weight: .medium))
                    Text(entry.hubID)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        sourceBadge(entry.source)
                        Text(sizeLabel(for: entry))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                        if let downloads = entry.downloads {
                            Text("· \(downloads.formatted())↓")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if downloaded.contains(entry.hubID) {
                        Text("On device")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    if loadedInMemory.contains(entry.hubID) {
                        Text("In memory")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }

            if activeDownload == entry.hubID, let p = downloadProgress[entry.hubID] {
                ProgressView(value: p)
                    .tint(Theme.accent)
                Text("Downloading… \(Int(p * 100))%")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 12) {
                Link(destination: entry.downloadURL) {
                    Text("Page")
                }
                .font(.subheadline.weight(.medium))

                if downloaded.contains(entry.hubID) {
                    if loadedInMemory.contains(entry.hubID) {
                        Button("Unload") {
                            Task { await unload(entry.hubID) }
                        }
                        .disabled(activeDownload != nil)
                    }
                    Button("Delete", role: .destructive) {
                        Task { await delete(entry.hubID) }
                    }
                    .disabled(activeDownload != nil)
                    Button("Use in chat") {
                        Task {
                            await state.refreshModels()
                            if let model = state.allModels.first(where: {
                                $0.provider == .localMetal && $0.modelID == entry.hubID
                            }) {
                                state.selectedModel = model
                                status = "Selected \(entry.displayName) for chat."
                            } else {
                                status = "Downloaded — refresh models if it doesn’t appear."
                            }
                        }
                    }
                    .disabled(activeDownload != nil)
                } else {
                    Button("Download") {
                        Task { await download(entry.hubID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(activeDownload != nil || !runtimeReady)
                }
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 4)
    }

    private func sourceBadge(_ source: LocalMetalCatalogEntry.Source) -> some View {
        let label: String = {
            switch source {
            case .recommended: return "Recommended"
            case .mlxSwiftRegistry: return "MLX Swift"
            case .huggingFace: return "HF"
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surfaceElevated, in: Capsule())
            .foregroundStyle(Theme.textSecondary)
    }

    private func sizeLabel(for entry: LocalMetalCatalogEntry) -> String {
        if let bytes = sizes[entry.hubID], bytes > 0 {
            return "On disk: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
        if !entry.approxSize.isEmpty {
            return "Download \(entry.approxSize)"
        }
        return "Download from Hugging Face"
    }

    private func refreshCatalog(force: Bool) async {
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        errorText = nil
        do {
            if force {
                _ = try await LocalMetalCatalog.shared.refreshFromHuggingFace()
            }
            entries = await LocalMetalCatalog.shared.allEntries(preferFreshRemote: force)
            lastCatalogFetch = await LocalMetalCatalog.shared.lastRemoteFetchDate()
            if force {
                status = "Catalog updated from Hugging Face (mlx-community)."
            }
        } catch {
            // Still show static + cached remote.
            entries = await LocalMetalCatalog.shared.allEntries(preferFreshRemote: false)
            lastCatalogFetch = await LocalMetalCatalog.shared.lastRemoteFetchDate()
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func reloadStatus() async {
        runtimeReady = LocalMetalRuntime.isReady
        var nextDownloaded = Set<String>()
        var nextSizes: [String: Int64] = [:]
        for entry in entries {
            let ready = await LocalMetalModelStore.shared.isDownloaded(modelID: entry.hubID)
            if ready {
                nextDownloaded.insert(entry.hubID)
                if let size = await LocalMetalModelStore.shared.approximateByteSize(modelID: entry.hubID) {
                    nextSizes[entry.hubID] = size
                }
            }
        }
        downloaded = nextDownloaded
        sizes = nextSizes

        if let engine = LocalMetalRuntime.engine {
            loadedInMemory = Set(await engine.loadedModelIDs())
        } else {
            loadedInMemory = []
        }
    }

    private func download(_ modelID: String) async {
        LocalMetalBootstrap.ensureRegistered()
        guard let engine = LocalMetalRuntime.engine else {
            errorText = "Metal runtime is not linked. Rebuild the iOS app with mlx-swift-lm packages."
            runtimeReady = false
            return
        }
        errorText = nil
        status = ""
        activeDownload = modelID
        downloadProgress[modelID] = 0
        defer { activeDownload = nil }
        do {
            try await engine.downloadModel(modelID: modelID) { fraction in
                Task { @MainActor in
                    downloadProgress[modelID] = fraction
                }
            }
            downloadProgress[modelID] = 1
            await state.refreshModels()
            await reloadStatus()
            status = "Downloaded. You can select it in the chat model picker."
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await reloadStatus()
        }
    }

    private func delete(_ modelID: String) async {
        LocalMetalBootstrap.ensureRegistered()
        guard let engine = LocalMetalRuntime.engine else {
            errorText = "Metal runtime is not linked."
            return
        }
        errorText = nil
        do {
            try await engine.deleteModel(modelID: modelID)
            if state.selectedModel?.modelID == modelID {
                state.selectedModel = state.allModels.first { $0.modelID != modelID }
            }
            await state.refreshModels()
            await reloadStatus()
            status = "Deleted — disk space freed."
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func unload(_ modelID: String) async {
        LocalMetalBootstrap.ensureRegistered()
        guard let engine = LocalMetalRuntime.engine else { return }
        await engine.unloadFromMemory(modelID: modelID)
        await reloadStatus()
        status = "Unloaded from memory (weights stay on disk)."
    }

    private func unloadAll() async {
        LocalMetalBootstrap.ensureRegistered()
        guard let engine = LocalMetalRuntime.engine else { return }
        await engine.unloadAllFromMemory()
        await reloadStatus()
        status = "All Metal models unloaded from memory."
    }
}

