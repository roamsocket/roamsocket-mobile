import SwiftUI
import AnyProvCore

/// Browse / download / delete on-device Metal models for **chat only** (not coding).
///
/// Layout mirrors common “Manage models” apps: Featured families → drill-in
/// variants with Download, plus Experimental / Legacy buckets and storage.
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
    @State private var storageUsed: Int64 = 0
    @State private var runtimeReady = false
    @State private var search = ""
    @State private var isRefreshingCatalog = false
    @State private var lastCatalogFetch: Date?
    @State private var showDeleteAllConfirm = false

    private var searchQuery: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleEntries: [LocalMetalCatalogEntry] {
        guard !searchQuery.isEmpty else { return entries }
        return entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchQuery)
                || $0.hubID.localizedCaseInsensitiveContains(searchQuery)
                || $0.family.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var featuredFamilies: [ModelFamilyGroup] {
        // Families that have at least one hand-picked / recommended model.
        // Include same-family standard variants so Gemma (etc.) is not split
        // across Featured and More models.
        let featuredFamilyNames = Set(
            visibleEntries
                .filter { $0.section == .featured || $0.source == .recommended }
                .map(\.family)
        )
        return familyGroups(
            from: visibleEntries.filter {
                featuredFamilyNames.contains($0.family)
                    && ($0.section == .featured
                        || $0.section == .standard
                        || $0.source == .recommended)
            }
        )
    }

    private var standardFamilies: [ModelFamilyGroup] {
        let featuredNames = Set(featuredFamilies.map(\.name))
        return familyGroups(
            from: visibleEntries.filter { $0.section == .standard }
        )
        .filter { !featuredNames.contains($0.name) }
    }

    private var experimentalEntries: [LocalMetalCatalogEntry] {
        visibleEntries.filter { $0.section == .experimental }
    }

    private var legacyEntries: [LocalMetalCatalogEntry] {
        visibleEntries.filter { $0.section == .legacy }
    }

    private var onDeviceEntries: [LocalMetalCatalogEntry] {
        visibleEntries.filter { downloaded.contains($0.hubID) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                introSection
                if !onDeviceEntries.isEmpty {
                    onDeviceSection
                }
                if searchQuery.isEmpty {
                    featuredSection
                    if !standardFamilies.isEmpty {
                        moreModelsSection
                    }
                    catalogLinksSection
                    storageSection
                } else {
                    searchResultsSection
                }
                statusSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Manage models")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refreshCatalog(force: true) }
                    } label: {
                        if isRefreshingCatalog {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshingCatalog)
                    .accessibilityLabel("Refresh catalog")
                }
            }
            .confirmationDialog(
                "Delete all on-device models?",
                isPresented: $showDeleteAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete all models", role: .destructive) {
                    Task { await deleteAllDownloaded() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes all Metal weights from this device. Cloud providers are not affected.")
            }
            .task {
                LocalMetalBootstrap.ensureRegistered()
                runtimeReady = LocalMetalRuntime.isReady
                await refreshCatalog(force: false)
                await reloadStatus()
            }
            .navigationDestination(for: ModelFamilyGroup.self) { family in
                ModelFamilyDetailView(
                    family: family,
                    downloaded: $downloaded,
                    loadedInMemory: $loadedInMemory,
                    downloadProgress: $downloadProgress,
                    activeDownload: $activeDownload,
                    sizes: $sizes,
                    runtimeReady: runtimeReady,
                    onDownload: { await download($0) },
                    onDelete: { await delete($0) },
                    onUnload: { await unload($0) },
                    onUse: { await useInChat($0) }
                )
            }
            .navigationDestination(for: CatalogBucket.self) { bucket in
                ModelBucketListView(
                    bucket: bucket,
                    entries: bucket == .experimental ? experimentalEntries : legacyEntries,
                    downloaded: $downloaded,
                    loadedInMemory: $loadedInMemory,
                    downloadProgress: $downloadProgress,
                    activeDownload: $activeDownload,
                    sizes: $sizes,
                    runtimeReady: runtimeReady,
                    onDownload: { await download($0) },
                    onDelete: { await delete($0) },
                    onUnload: { await unload($0) },
                    onUse: { await useInChat($0) }
                )
            }
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run open models on this device with Metal (MLX). Chat only — coding sessions use a cloud or desktop provider.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    Circle()
                        .fill(runtimeReady ? Color.green.opacity(0.9) : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(runtimeReady
                         ? "Metal runtime ready"
                         : "Metal runtime not ready — rebuild with MLX packages")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.surface)
        }
    }

    private var onDeviceSection: some View {
        Section {
            ForEach(onDeviceEntries) { entry in
                modelVariantRow(entry, showFamily: true)
            }
        } header: {
            Text("On this device")
        }
    }

    private var featuredSection: some View {
        Section {
            if featuredFamilies.isEmpty {
                Text("No featured models. Pull to refresh the catalog.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(featuredFamilies) { family in
                    NavigationLink(value: family) {
                        familyCard(family)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        } header: {
            Text("Featured")
        } footer: {
            if let lastCatalogFetch {
                Text("Catalog · LM Studio + mlx-swift-lm · \(lastCatalogFetch.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
            }
        }
    }

    private var moreModelsSection: some View {
        Section {
            ForEach(standardFamilies) { family in
                NavigationLink(value: family) {
                    familyCard(family)
                }
                .listRowBackground(Theme.surface)
            }
        } header: {
            Text("More models")
        }
    }

    private var catalogLinksSection: some View {
        Section {
            NavigationLink(value: CatalogBucket.legacy) {
                bucketRow(
                    title: "Legacy models",
                    systemImage: "archivebox",
                    subtitle: "Older or larger variants that may be limited on phones.",
                    count: legacyEntries.count
                )
            }
            .listRowBackground(Theme.surface)

            NavigationLink(value: CatalogBucket.experimental) {
                bucketRow(
                    title: "Experimental models",
                    systemImage: "flask",
                    subtitle: "Live LM Studio catalog — may include larger variants.",
                    count: experimentalEntries.count
                )
            }
            .listRowBackground(Theme.surface)
        }
    }

    private var storageSection: some View {
        Section {
            HStack {
                Text("Storage used")
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: storageUsed, countStyle: .file))
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)

            Button(role: .destructive) {
                showDeleteAllConfirm = true
            } label: {
                Text("Delete all models")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(downloaded.isEmpty || activeDownload != nil)
            .listRowBackground(Theme.surface)
        } footer: {
            Text("On-device models may produce inaccurate responses. Verify critical information. Models are provided via huggingface.co.")
        }
    }

    private var searchResultsSection: some View {
        Section {
            if visibleEntries.isEmpty {
                Text("No models match “\(searchQuery)”.")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(visibleEntries) { entry in
                    modelVariantRow(entry, showFamily: true)
                }
            }
        } header: {
            Text("Results")
        }
    }

    private var statusSection: some View {
        Section {
            if !loadedInMemory.isEmpty {
                Button("Unload all from memory") {
                    Task { await unloadAll() }
                }
            }
            Button("Refresh chat model list") {
                Task {
                    await state.refreshModels()
                    status = "Chat model list updated (\(state.allModels.filter { $0.provider == .localMetal }.count) on-device)."
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
        } footer: {
            Text("Unload frees RAM but keeps downloads. Delete removes weights from this device.")
        }
    }

    // MARK: - Cards / rows

    private func familyCard(_ family: ModelFamilyGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(family.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if family.models.contains(where: { downloaded.contains($0.hubID) }) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            Text(family.blurb)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(family.models.count) model\(family.models.count == 1 ? "" : "s")")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
            if !family.tags.isEmpty {
                tagRow(family.tags)
            }
        }
        .padding(.vertical, 4)
    }

    private func bucketRow(title: String, systemImage: String, subtitle: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 32)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func modelVariantRow(_ entry: LocalMetalCatalogEntry, showFamily: Bool) -> some View {
        ModelDownloadRow(
            entry: entry,
            showFamily: showFamily,
            isDownloaded: downloaded.contains(entry.hubID),
            isLoaded: loadedInMemory.contains(entry.hubID),
            progress: activeDownload == entry.hubID ? downloadProgress[entry.hubID] : nil,
            sizeLabel: sizeLabel(for: entry),
            runtimeReady: runtimeReady,
            busy: activeDownload != nil,
            onDownload: { Task { await download(entry.hubID) } },
            onDelete: { Task { await delete(entry.hubID) } },
            onUnload: { Task { await unload(entry.hubID) } },
            onUse: { Task { await useInChat(entry.hubID) } }
        )
        .listRowBackground(Theme.surface)
    }

    private func tagRow(_ tags: [LocalMetalCatalogEntry.Tag]) -> some View {
        FlowTagMap(tags: tags)
    }

    private func sizeLabel(for entry: LocalMetalCatalogEntry) -> String {
        if let bytes = sizes[entry.hubID], bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if !entry.approxSize.isEmpty { return entry.approxSize }
        return "Download from Hugging Face"
    }

    // MARK: - Grouping

    private func familyGroups(from list: [LocalMetalCatalogEntry]) -> [ModelFamilyGroup] {
        let grouped = Dictionary(grouping: list, by: \.family)
        return grouped.keys.sorted().compactMap { name -> ModelFamilyGroup? in
            guard var models = grouped[name], !models.isEmpty else { return nil }
            models.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            let tags = Array(Set(models.flatMap(\.tags)))
                .sorted { $0.rawValue < $1.rawValue }
            return ModelFamilyGroup(
                name: name,
                blurb: LocalMetalCatalog.familyBlurb(name),
                models: models,
                tags: tags
            )
        }
    }

    // MARK: - Actions

    private func refreshCatalog(force: Bool) async {
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        errorText = nil
        do {
            if force {
                _ = try await LocalMetalCatalog.shared.refreshFromLMStudio()
            }
            entries = await LocalMetalCatalog.shared.allEntries(preferFreshRemote: force)
            lastCatalogFetch = await LocalMetalCatalog.shared.lastRemoteFetchDate()
            if force {
                status = "Catalog updated from LM Studio."
            }
        } catch {
            entries = await LocalMetalCatalog.shared.allEntries(preferFreshRemote: false)
            lastCatalogFetch = await LocalMetalCatalog.shared.lastRemoteFetchDate()
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await reloadStatus()
    }

    private func reloadStatus() async {
        runtimeReady = LocalMetalRuntime.isReady
        var nextDownloaded = Set<String>()
        var nextSizes: [String: Int64] = [:]

        // Always include persisted downloads.
        let known = await LocalMetalModelStore.shared.knownDownloadedIDs()
        for id in known {
            if await LocalMetalModelStore.shared.isDownloaded(modelID: id) {
                nextDownloaded.insert(id)
            }
        }

        for entry in entries {
            let ready = await LocalMetalModelStore.shared.isDownloaded(modelID: entry.hubID)
            if ready {
                nextDownloaded.insert(entry.hubID)
                if let size = await LocalMetalModelStore.shared.approximateByteSize(modelID: entry.hubID) {
                    nextSizes[entry.hubID] = size
                }
            }
        }

        // Scan any hub folders not in catalog.
        if let listed = try? await LocalMetalModelStore.shared.listModels() {
            for model in listed where model.provider == .localMetal {
                nextDownloaded.insert(model.modelID)
            }
        }

        downloaded = nextDownloaded
        sizes = nextSizes
        storageUsed = await LocalMetalModelStore.shared.totalStorageBytes()

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
        status = "Downloading…"
        activeDownload = modelID
        downloadProgress[modelID] = 0
        // Optimistic UI while finishing.
        defer {
            activeDownload = nil
        }
        do {
            try await engine.downloadModel(modelID: modelID) { fraction in
                Task { @MainActor in
                    // Keep the bar monotonic so late/out-of-order samples don't jump back.
                    let previous = downloadProgress[modelID] ?? 0
                    if fraction > previous {
                        downloadProgress[modelID] = fraction
                    }
                }
            }
            downloadProgress[modelID] = 1
            await LocalMetalModelStore.shared.markDownloaded(modelID: modelID)
            // Update UI immediately so the button flips before refresh finishes.
            downloaded.insert(modelID)
            await state.refreshModels()
            // Downloads stay on disk only; load into RAM only if this model is selected.
            if state.selectedModel?.provider == .localMetal,
               state.selectedModel?.modelID == modelID {
                await state.ensureSelectedLocalMetalLoaded()
            }
            await reloadStatus()
            let inPicker = state.allModels.contains {
                $0.provider == .localMetal && $0.modelID == modelID
            }
            status = inPicker
                ? "Downloaded — select it in the model picker to load into memory."
                : "Downloaded. Tap “Refresh chat model list” if it isn’t in the picker yet."
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
            await LocalMetalModelStore.shared.markDeleted(modelID: modelID)
            downloaded.remove(modelID)
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

    private func deleteAllDownloaded() async {
        let ids = Array(downloaded)
        for id in ids {
            await delete(id)
        }
        status = "All on-device models deleted."
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

    private func useInChat(_ modelID: String) async {
        await state.refreshModels()
        if let model = state.allModels.first(where: {
            $0.provider == .localMetal && $0.modelID == modelID
        }) {
            state.selectedModel = model
            status = "Selected \(model.displayName) for chat."
            dismiss()
        } else {
            // Still not listed — force a store re-scan after mark.
            await LocalMetalModelStore.shared.markDownloaded(modelID: modelID)
            await state.refreshModels()
            if let model = state.allModels.first(where: {
                $0.provider == .localMetal && $0.modelID == modelID
            }) {
                state.selectedModel = model
                status = "Selected \(model.displayName) for chat."
                dismiss()
            } else {
                status = "Downloaded, but not in the picker yet. Try Refresh chat model list."
            }
        }
    }
}

// MARK: - Family / bucket models

struct ModelFamilyGroup: Hashable, Identifiable {
    var id: String { name }
    let name: String
    let blurb: String
    let models: [LocalMetalCatalogEntry]
    let tags: [LocalMetalCatalogEntry.Tag]
}

enum CatalogBucket: String, Hashable {
    case legacy
    case experimental

    var title: String {
        switch self {
        case .legacy: return "Legacy models"
        case .experimental: return "Experimental models"
        }
    }
}

// MARK: - Family detail

private struct ModelFamilyDetailView: View {
    let family: ModelFamilyGroup
    @Binding var downloaded: Set<String>
    @Binding var loadedInMemory: Set<String>
    @Binding var downloadProgress: [String: Double]
    @Binding var activeDownload: String?
    @Binding var sizes: [String: Int64]
    let runtimeReady: Bool
    var onDownload: (String) async -> Void
    var onDelete: (String) async -> Void
    var onUnload: (String) async -> Void
    var onUse: (String) async -> Void

    var body: some View {
        List {
            Section {
                Text(family.blurb)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.surface)
            }

            Section {
                ForEach(family.models) { entry in
                    ModelDownloadRow(
                        entry: entry,
                        showFamily: false,
                        isDownloaded: downloaded.contains(entry.hubID),
                        isLoaded: loadedInMemory.contains(entry.hubID),
                        progress: activeDownload == entry.hubID ? downloadProgress[entry.hubID] : nil,
                        sizeLabel: sizeLabel(entry),
                        runtimeReady: runtimeReady,
                        busy: activeDownload != nil,
                        onDownload: { Task { await onDownload(entry.hubID) } },
                        onDelete: { Task { await onDelete(entry.hubID) } },
                        onUnload: { Task { await onUnload(entry.hubID) } },
                        onUse: { Task { await onUse(entry.hubID) } }
                    )
                    .listRowBackground(Theme.surface)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(family.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sizeLabel(_ entry: LocalMetalCatalogEntry) -> String {
        if let bytes = sizes[entry.hubID], bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if !entry.approxSize.isEmpty { return entry.approxSize }
        return "From Hugging Face"
    }
}

// MARK: - Bucket list

private struct ModelBucketListView: View {
    let bucket: CatalogBucket
    let entries: [LocalMetalCatalogEntry]
    @Binding var downloaded: Set<String>
    @Binding var loadedInMemory: Set<String>
    @Binding var downloadProgress: [String: Double]
    @Binding var activeDownload: String?
    @Binding var sizes: [String: Int64]
    let runtimeReady: Bool
    var onDownload: (String) async -> Void
    var onDelete: (String) async -> Void
    var onUnload: (String) async -> Void
    var onUse: (String) async -> Void

    private var groups: [ModelFamilyGroup] {
        let grouped = Dictionary(grouping: entries, by: \.family)
        return grouped.keys.sorted().compactMap { name in
            guard var models = grouped[name], !models.isEmpty else { return nil }
            models.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return ModelFamilyGroup(
                name: name,
                blurb: LocalMetalCatalog.familyBlurb(name),
                models: models,
                tags: []
            )
        }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No models",
                    systemImage: bucket == .legacy ? "archivebox" : "flask",
                    description: Text("Refresh the catalog or try another section.")
                )
            } else {
                ForEach(groups) { family in
                    Section(family.name) {
                        ForEach(family.models) { entry in
                            ModelDownloadRow(
                                entry: entry,
                                showFamily: false,
                                isDownloaded: downloaded.contains(entry.hubID),
                                isLoaded: loadedInMemory.contains(entry.hubID),
                                progress: activeDownload == entry.hubID ? downloadProgress[entry.hubID] : nil,
                                sizeLabel: sizeLabel(entry),
                                runtimeReady: runtimeReady,
                                busy: activeDownload != nil,
                                onDownload: { Task { await onDownload(entry.hubID) } },
                                onDelete: { Task { await onDelete(entry.hubID) } },
                                onUnload: { Task { await onUnload(entry.hubID) } },
                                onUse: { Task { await onUse(entry.hubID) } }
                            )
                            .listRowBackground(Theme.surface)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(bucket.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sizeLabel(_ entry: LocalMetalCatalogEntry) -> String {
        if let bytes = sizes[entry.hubID], bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if !entry.approxSize.isEmpty { return entry.approxSize }
        return "From Hugging Face"
    }
}

// MARK: - Download row

private struct ModelDownloadRow: View {
    let entry: LocalMetalCatalogEntry
    var showFamily: Bool
    let isDownloaded: Bool
    let isLoaded: Bool
    let progress: Double?
    let sizeLabel: String
    let runtimeReady: Bool
    let busy: Bool
    var onDownload: () -> Void
    var onDelete: () -> Void
    var onUnload: () -> Void
    var onUse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if showFamily {
                        Text(entry.family)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
                    if !entry.blurb.isEmpty {
                        Text(entry.blurb)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(entry.hubID)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Text(sizeLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                trailingControls
            }

            // Full-width tags so the Download control never compresses pill labels.
            if !entry.tags.isEmpty {
                FlowTagMap(tags: entry.tags)
            }

            if let progress {
                ProgressView(value: min(1, max(0, progress)))
                    .tint(Theme.accent)
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var trailingControls: some View {
        if isDownloaded {
            VStack(alignment: .trailing, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                    .accessibilityLabel("Downloaded")
                Menu {
                    Button("Use in chat", action: onUse)
                    if isLoaded {
                        Button("Unload from memory", action: onUnload)
                    }
                    Link("Open on Hugging Face", destination: entry.downloadURL)
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textSecondary)
                }
                .disabled(busy)
            }
        } else {
            Button(action: onDownload) {
                Text(progress != nil ? "…" : "Download")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceElevated, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy || !runtimeReady || progress != nil)
        }
    }
}

// MARK: - Tags

/// Horizontal chip row that wraps *whole* pills onto the next line instead of
/// letting label text reflow inside a capsule (e.g. “Recommende / d”).
private struct FlowTagMap: View {
    let tags: [LocalMetalCatalogEntry.Tag]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(foreground(for: tag))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(background(for: tag), in: Capsule())
            }
        }
    }

    private func foreground(for tag: LocalMetalCatalogEntry.Tag) -> Color {
        switch tag {
        case .recommended, .best: return Color.green
        case .thinking: return Color.purple
        case .vision: return Color.yellow
        case .new: return Color.orange
        case .experimental: return Color.cyan
        case .legacy: return Theme.textSecondary
        }
    }

    private func background(for tag: LocalMetalCatalogEntry.Tag) -> Color {
        foreground(for: tag).opacity(0.18)
    }
}

/// Simple left-to-right, wrap-on-overflow layout for chip rows.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }

        let height = y + rowHeight
        // Prefer the proposed width when finite so parents get a stable layout.
        if let width = proposal.width, width.isFinite {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: totalWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
