import Foundation
import CoreImage
import AnyProvCore
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Real Metal-backed chat engine using mlx-swift-lm + Hugging Face hub.
///
/// **Chat only** — coding sessions never select `ProviderID.localMetal`.
/// Weights are **never bundled**; they download into Application Support.
enum LocalMetalMLXBackend {
    /// Registers the MLX engine so `LocalMetalBootstrap` can wire it in.
    static func register() {
        shared = Engine()
    }

    /// Non-nil after `register()`.
    static var shared: (any LocalMetalGenerating)?
}

// MARK: - Engine

private final class Engine: LocalMetalGenerating, @unchecked Sendable {
    private let cache = ContainerCache()

    private let hubCache: HubCache
    private let hubClient: HubClient

    init() {
        // Must match LocalMetalModelStore / LocalMetalPaths so downloads appear
        // in Settings, chat picker, and Vision. Falls back to legacy AnyProvCode
        // only when that tree already has weights (migration).
        let dir = (try? LocalMetalModelStore.shared.hubCacheDirectorySync())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CodeSocket-hf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hubCache = HubCache(cacheDirectory: dir)
        self.hubCache = hubCache
        self.hubClient = HubClient(cache: hubCache)
    }

    // MARK: LocalMetalGenerating

    func generate(
        modelID: String,
        messages: [ProviderChatMessage],
        effort: Effort?
    ) async throws -> String {
        guard await isDownloaded(modelID: modelID) else {
            throw ProviderError.transport(
                "Model “\(modelID)” is not downloaded. Open Settings → On-device (Metal) and tap Download (weights are not bundled in the app)."
            )
        }

        let hasImages = messages.contains(where: \.hasImages)
        let useVLM = hasImages || Self.isLikelyVLM(modelID)
        if hasImages && !Self.isLikelyVLM(modelID) {
            throw ProviderError.transport(
                "This on-device model does not support vision. Download a Vision model (Gemma 4, Qwen2-VL, SmolVLM, …) from Settings → On-device (Metal)."
            )
        }

        // Lazy fallback if selection preload hasn't finished yet.
        let container = try await loadContainer(
            id: modelID,
            keepInMemory: true,
            preferVLM: useVLM,
            progress: { _ in }
        )
        let params = generateParameters(effort: effort)

        let systemText = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let conversation = messages.filter { $0.role != .system }

        guard let last = conversation.last else {
            throw ProviderError.transport("Nothing to generate — empty conversation.")
        }

        let history: [Chat.Message] = conversation.dropLast().map { mapMessage($0) }

        let session: ChatSession
        if history.isEmpty {
            session = ChatSession(
                container,
                instructions: systemText.isEmpty ? nil : systemText,
                generateParameters: params
            )
        } else {
            session = ChatSession(
                container,
                instructions: systemText.isEmpty ? nil : systemText,
                history: history,
                generateParameters: params
            )
        }

        do {
            switch last.role {
            case .user:
                if last.hasImages {
                    let images = try Self.userInputImages(from: last.images)
                    let prompt = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let output = try await session.respond(
                        to: prompt.isEmpty ? "Describe this image." : prompt,
                        images: images,
                        videos: [],
                        audios: []
                    )
                    return try nonEmpty(output)
                }
                let output = try await session.respond(to: last.content)
                return try nonEmpty(output)
            case .assistant, .system:
                let all = conversation.map { mapMessage($0) }
                let output = try await session.respond(to: all)
                return try nonEmpty(output)
            }
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport(
                "Metal generation failed: \(error.localizedDescription)"
            )
        }
    }

    func downloadModel(
        modelID: String,
        progress: @escaping @Sendable (LocalMetalDownloadProgress) -> Void
    ) async throws {
        // Disk-only hub snapshot — do **not** load into MLX here. Loading via
        // `loadContainer` previously hid real byte progress (UI stuck ~2–4% while
        // large weights transferred, then jumped to 100% after load finished).
        if modelID.hasPrefix("local/") {
            progress(LocalMetalDownloadProgress(fraction: 1, status: "Ready"))
            await LocalMetalModelStore.shared.markDownloaded(modelID: modelID)
            return
        }

        guard let repoID = Repo.ID(rawValue: modelID) else {
            throw ProviderError.transport("Invalid model id “\(modelID)”.")
        }

        progress(LocalMetalDownloadProgress(fraction: 0, status: "Listing files…"))

        let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        let broker = DownloadProgressBroker(emit: progress)

        // Expected size from the hub tree so we can report true byte progress even
        // when Foundation Progress freezes mid-file and while URLSession stages
        // multi‑GB weights in tmp/ before they land in the hub cache.
        do {
            let expected = try await Self.expectedDownloadBytes(
                hubClient: hubClient,
                repoID: repoID,
                patterns: Self.modelDownloadPatterns
            )
            if expected > 0 {
                await broker.setExpectedBytes(expected)
                progress(LocalMetalDownloadProgress(
                    fraction: 0,
                    status: "Preparing download…",
                    bytesDownloaded: 0,
                    bytesTotal: expected
                ))
            } else {
                progress(LocalMetalDownloadProgress(fraction: 0, status: "Preparing download…"))
            }
        } catch {
            // Tree size is optional; continue with hub Progress alone.
            progress(LocalMetalDownloadProgress(fraction: 0, status: "Preparing download…"))
        }

        // Baseline tmp occupancy so we only attribute *growth* to this download
        // (other URLSession traffic must not inflate the bar).
        let tmpBaseline = Self.largeTempFileBytes()
        await broker.setTempBaseline(tmpBaseline)

        // Seed UI from anything already cached (resume / retry).
        await broker.noteObservedBytes(
            cacheBytes: Self.directoryByteSize(at: repoDir),
            tempBytes: tmpBaseline,
            status: "Resuming…"
        )

        // Poll cache + large temp files + last hub Progress at ~10 Hz.
        let diskPoll = Task {
            while !Task.isCancelled {
                let cacheBytes = Self.directoryByteSize(at: repoDir)
                let tempBytes = Self.largeTempFileBytes()
                await broker.noteObservedBytes(
                    cacheBytes: cacheBytes,
                    tempBytes: tempBytes,
                    status: "Downloading weights…"
                )
                await broker.rescanHubProgress()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        do {
            await broker.setStatus("Downloading weights…")
            // Same patterns mlx-swift-lm uses for chat weights + tokenizer.
            _ = try await hubClient.downloadSnapshot(
                of: repoID,
                revision: "main",
                matching: Self.modelDownloadPatterns,
                progressHandler: { @MainActor p in
                    // Fire-and-forget onto the broker actor; sampling is ~10 Hz.
                    Task(priority: .userInitiated) {
                        await broker.noteHubProgress(p)
                    }
                }
            )
            diskPoll.cancel()
            _ = await diskPoll.result
            await broker.finish()
            // Persist so Settings UI + model picker see the model even if cache
            // layout detection is flaky (HF hub uses blobs + snapshot symlinks).
            await LocalMetalModelStore.shared.markDownloaded(modelID: modelID)
        } catch {
            diskPoll.cancel()
            _ = await diskPoll.result
            throw ProviderError.transport(
                "Failed to download on-device model “\(modelID)”: \(error.localizedDescription). " +
                "Check network, then retry. Models are not bundled in the app."
            )
        }
    }

    func loadIntoMemory(
        modelID: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard await isDownloaded(modelID: modelID) else {
            throw ProviderError.transport(
                "Model “\(modelID)” is not downloaded. Open Settings → Manage models and tap Download."
            )
        }
        _ = try await loadContainer(
            id: modelID,
            keepInMemory: true,
            preferVLM: Self.isLikelyVLM(modelID),
            progress: progress
        )
        progress(1)
    }

    func deleteModel(modelID: String) async throws {
        await unloadFromMemory(modelID: modelID)

        if modelID.hasPrefix("local/") {
            let name = String(modelID.dropFirst("local/".count))
            if let dir = try? await LocalMetalModelStore.shared.modelsDirectory() {
                let folder = dir.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.removeItem(at: folder)
                }
            }
            await LocalMetalModelStore.shared.markDeleted(modelID: modelID)
            return
        }

        guard let repoID = Repo.ID(rawValue: modelID) else {
            throw ProviderError.transport("Invalid model id “\(modelID)”.")
        }
        // Engine cache root (CodeSocket or legacy AnyProvCode, whichever we bind to).
        let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        if FileManager.default.fileExists(atPath: repoDir.path) {
            try FileManager.default.removeItem(at: repoDir)
        }
        // Also wipe the same hub id under every known app-support hub root so
        // split CodeSocket / AnyProvCode trees cannot leave orphan weights.
        let folderName = LocalMetalPaths.hubRepoFolderName(for: modelID)
        for root in LocalMetalPaths.hubCacheRootsToScan() {
            let extra = root.appendingPathComponent(folderName, isDirectory: true)
            if extra.standardizedFileURL != repoDir.standardizedFileURL,
               FileManager.default.fileExists(atPath: extra.path) {
                try? FileManager.default.removeItem(at: extra)
            }
        }
        await LocalMetalModelStore.shared.markDeleted(modelID: modelID)
    }

    func unloadFromMemory(modelID: String) async {
        await cache.remove(modelID)
        // Free Metal/MLX intermediate buffers held by the runtime.
        Memory.clearCache()
    }

    func unloadAllFromMemory() async {
        await cache.removeAll()
        Memory.clearCache()
    }

    func isDownloaded(modelID: String) async -> Bool {
        if modelID.hasPrefix("local/") {
            let name = String(modelID.dropFirst("local/".count))
            // Canonical + legacy LocalModels roots.
            if await LocalMetalModelStore.shared.isDownloadedOnDisk(modelID: modelID) {
                return true
            }
            if let dir = try? await LocalMetalModelStore.shared.modelsDirectory() {
                let folder = dir.appendingPathComponent(name, isDirectory: true)
                return LocalMetalModelStore.hasUsableModelCache(at: folder)
            }
            return false
        }
        // In-memory container from a just-finished download counts as ready.
        if await cache.get(modelID) != nil { return true }
        guard let repoID = Repo.ID(rawValue: modelID) else { return false }
        let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        if LocalMetalModelStore.hasUsableModelCache(at: repoDir) { return true }
        // Fallback: store scans CodeSocket + legacy AnyProvCode trees.
        return await LocalMetalModelStore.shared.isDownloadedOnDisk(modelID: modelID)
    }

    func isLoadedInMemory(modelID: String) async -> Bool {
        await cache.get(modelID) != nil
    }

    func loadedModelIDs() async -> [String] {
        await cache.ids()
    }

    // MARK: - Load

    private func loadContainer(
        id: String,
        keepInMemory: Bool,
        preferVLM: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
        if let cached = await cache.get(id) {
            progress(1)
            return cached
        }

        // Single-flight: selection preload + first chat send must not both load
        // the same multi-GB model into RAM.
        do {
            let container = try await cache.getOrLoad(id: id) { [hubClient] report in
                let configuration: ModelConfiguration
                if id.hasPrefix("local/") {
                    let name = String(id.dropFirst("local/".count))
                    if let dir = try? await LocalMetalModelStore.shared.modelsDirectory() {
                        let folder = dir.appendingPathComponent(name, isDirectory: true)
                        if FileManager.default.fileExists(atPath: folder.path) {
                            configuration = ModelConfiguration(directory: folder)
                        } else {
                            configuration = ModelConfiguration(id: name)
                        }
                    } else {
                        configuration = ModelConfiguration(id: name)
                    }
                } else {
                    configuration = ModelConfiguration(id: id)
                }

                // Explicit hub client so weights land in Application Support (deletable).
                // VLMs (Gemma 4, Qwen-VL, …) must load via VLMModelFactory.
                let useVLM = preferVLM || Self.isLikelyVLM(id)
                if useVLM {
                    return try await VLMModelFactory.shared.loadContainer(
                        from: #hubDownloader(hubClient),
                        using: #huggingFaceTokenizerLoader(),
                        configuration: configuration,
                        progressHandler: { p in
                            report(DownloadProgressBroker.fraction(from: p))
                        }
                    )
                }
                return try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(hubClient),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: { p in
                        report(DownloadProgressBroker.fraction(from: p))
                    }
                )
            } progress: { fraction in
                progress(fraction)
            }
            if !keepInMemory {
                // Load was shared; drop if caller only needed a transient container.
                await cache.remove(id)
            }
            progress(1)
            return container
        } catch {
            throw ProviderError.transport(
                "Failed to load on-device model “\(id)”: \(error.localizedDescription). " +
                "Check network for the download, then retry. Models are not bundled in the app."
            )
        }
    }

    // MARK: - Download progress

    /// Matches mlx-swift-lm `modelDownloadPatterns` (package-internal, re-stated here).
    private static let modelDownloadPatterns = ["*.safetensors", "*.json", "*.jinja"]

    /// Sum of file sizes for hub entries matching our download globs.
    private static func expectedDownloadBytes(
        hubClient: HubClient,
        repoID: Repo.ID,
        patterns: [String]
    ) async throws -> Int64 {
        let entries = try await hubClient.listFiles(in: repoID, kind: .model, revision: "main", recursive: true)
        var total: Int64 = 0
        for entry in entries {
            guard entry.type == .file else { continue }
            guard matchesGlobPatterns(entry.path, patterns: patterns) else { continue }
            total += Int64(entry.size ?? 0)
        }
        return total
    }

    private static func matchesGlobPatterns(_ path: String, patterns: [String]) -> Bool {
        if patterns.isEmpty { return true }
        let name = (path as NSString).lastPathComponent
        for pattern in patterns {
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1)) // e.g. ".safetensors"
                if name.lowercased().hasSuffix(suffix.lowercased()) { return true }
            } else if name == pattern || path == pattern || path.hasSuffix("/" + pattern) {
                return true
            }
        }
        return false
    }

    /// Best-effort size of a hub repo cache tree (blobs + incomplete + snapshots).
    private static func directoryByteSize(at root: URL) -> Int64 {
        sumRegularFileBytes(at: root)
    }

    /// Sum of large regular files under the app temp directory.
    ///
    /// `URLSession.download` streams multi‑GB weights into tmp first; the hub cache
    /// only grows when each file is finalized. Counting large tmp files (with a
    /// pre-download baseline) is how mid-file progress becomes visible.
    private static func largeTempFileBytes(minimumBytes: Int64 = 8 * 1024 * 1024) -> Int64 {
        let fm = FileManager.default
        var roots: [URL] = [fm.temporaryDirectory]
        let nsTmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        if nsTmp.standardizedFileURL != fm.temporaryDirectory.standardizedFileURL {
            roots.append(nsTmp)
        }

        var total: Int64 = 0
        var seen = Set<String>()
        for root in roots {
            let path = root.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            // Shallow: URLSession stages CFNetworkDownload_* files near tmp root.
            total += sumRegularFileBytes(at: root, minimumBytes: minimumBytes, maxDepth: 3)
        }
        return total
    }

    private static func sumRegularFileBytes(
        at root: URL,
        minimumBytes: Int64 = 0,
        maxDepth: Int? = nil
    ) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .totalFileAllocatedSizeKey,
                    .fileSizeKey,
                ],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
              )
        else { return 0 }

        var total: Int64 = 0
        let rootDepth = root.pathComponents.count
        for case let fileURL as URL in enumerator {
            if let maxDepth {
                let depth = fileURL.pathComponents.count - rootDepth
                if depth > maxDepth {
                    enumerator.skipDescendants()
                    continue
                }
            }
            let size = fileByteSize(fileURL)
            if size >= minimumBytes {
                total += size
            }
        }
        return total
    }

    private static func fileByteSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        ), values.isRegularFile == true
        else { return 0 }
        if let allocated = values.totalFileAllocatedSize {
            return Int64(allocated)
        }
        if let size = values.fileSize {
            return Int64(size)
        }
        return 0
    }

    // MARK: - Helpers

    private func mapMessage(_ turn: ProviderChatMessage) -> Chat.Message {
        switch turn.role {
        case .user: return .user(turn.content)
        case .assistant: return .assistant(turn.content)
        case .system: return .system(turn.content)
        }
    }

    /// Hub-id heuristic matching VisionCapability / MLXVLM registry families.
    private static func isLikelyVLM(_ modelID: String) -> Bool {
        LocalMetalCatalog.isLikelyVisionHubID(modelID)
    }

    private static func userInputImages(
        from attachments: [ProviderChatMessage.ImageAttachment]
    ) throws -> [UserInput.Image] {
        try attachments.map { attachment in
            guard let data = Data(base64Encoded: attachment.base64Data),
                  let ciImage = CIImage(data: data)
            else {
                throw ProviderError.transport("Could not decode the captured photo for on-device vision.")
            }
            return .ciImage(ciImage)
        }
    }

    private func nonEmpty(_ output: String) throws -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderError.transport("Model returned an empty response.")
        }
        return trimmed
    }

    private func generateParameters(effort: Effort?) -> GenerateParameters {
        let maxTokens: Int
        let temperature: Float
        switch effort {
        case .low:
            maxTokens = 256
            temperature = 0.2
        case .high:
            maxTokens = 2048
            temperature = 0.8
        default:
            maxTokens = 1024
            temperature = 0.6
        }
        return GenerateParameters(maxTokens: maxTokens, temperature: temperature)
    }
}

// MARK: - Progress broker

/// Merges Hugging Face `Progress` with on-disk + tmp staging growth into a monotonic 0…1
/// plus human step status (mirrors desktop Metal download progress).
///
/// URLSession downloads multi‑GB weights into a temp file first; the hub cache only
/// grows when each file finishes. Foundation hierarchical `Progress` also freezes
/// mid-file in some cases. We combine:
///   - hub `Progress.fractionCompleted` / unit counts
///   - hub cache size (blobs + incomplete + snapshots)
///   - growth of large files under the app temp directory
private actor DownloadProgressBroker {
    private let emit: @Sendable (LocalMetalDownloadProgress) -> Void
    private var bestFraction: Double = 0
    private var expectedBytes: Int64 = 0
    private var lastEmitted: Double = -1
    private var lastStatusKey = ""
    private var tempBaseline: Int64 = 0
    private var status: String = "Downloading weights…"
    private var currentFile: String?
    private var bytesDownloaded: Int64 = 0
    /// Last Progress object from the hub client (sampled between handler callbacks).
    private var lastHubProgress: Progress?

    init(emit: @escaping @Sendable (LocalMetalDownloadProgress) -> Void) {
        self.emit = emit
    }

    func setExpectedBytes(_ bytes: Int64) {
        expectedBytes = max(expectedBytes, bytes)
    }

    func setTempBaseline(_ bytes: Int64) {
        tempBaseline = max(0, bytes)
    }

    func setStatus(_ text: String) {
        status = text
        publish(bestFraction, force: true)
    }

    func noteHubProgress(_ progress: Progress) {
        lastHubProgress = progress
        if progress.totalUnitCount > 1_024 {
            expectedBytes = max(expectedBytes, progress.totalUnitCount)
        }
        // Prefer hub-provided step labels when present (file counts, names).
        if let label = Self.statusLabel(from: progress) {
            status = label
        }
        if let file = Self.fileLabel(from: progress) {
            currentFile = file
        }
        if progress.totalUnitCount > 0, progress.completedUnitCount >= 0 {
            // When unit counts look like bytes, surface them.
            if progress.totalUnitCount > 1_024 * 1_024 {
                bytesDownloaded = max(bytesDownloaded, progress.completedUnitCount)
                expectedBytes = max(expectedBytes, progress.totalUnitCount)
            }
        }
        raise(Self.fraction(from: progress))
    }

    /// Re-read the last hub Progress (URLSession updates it off-thread).
    func rescanHubProgress() {
        guard let progress = lastHubProgress else { return }
        if let label = Self.statusLabel(from: progress) {
            status = label
        }
        if let file = Self.fileLabel(from: progress) {
            currentFile = file
        }
        raise(Self.fraction(from: progress))
    }

    /// Cache bytes + absolute temp occupancy (baseline subtracted inside).
    func noteObservedBytes(cacheBytes: Int64, tempBytes: Int64, status hint: String? = nil) {
        let staging = max(0, tempBytes - tempBaseline)
        let received = max(0, cacheBytes) + staging
        bytesDownloaded = max(bytesDownloaded, received)
        if let hint, currentFile == nil {
            status = hint
        }
        if expectedBytes > 1_024 {
            raise(min(0.99, Double(received) / Double(expectedBytes)))
        } else if received > 1_024 * 1_024 {
            // No tree size yet — soft estimate so the bar still moves.
            status = "Downloading weights…"
            raise(min(0.5, Double(received) / 4_000_000_000))
        }
    }

    func finish() {
        status = "Ready"
        currentFile = nil
        if expectedBytes > 0 {
            bytesDownloaded = max(bytesDownloaded, expectedBytes)
        }
        publish(1, force: true)
    }

    private func raise(_ value: Double) {
        let clamped = min(0.99, max(0, value))
        guard clamped > bestFraction + 0.0005 || (clamped > 0 && bestFraction == 0) else {
            if clamped > bestFraction { bestFraction = clamped }
            // Still push status/file changes even if fraction barely moved.
            publish(bestFraction, force: false)
            return
        }
        bestFraction = clamped
        publish(bestFraction, force: false)
    }

    private func publish(_ raw: Double, force: Bool) {
        let value = min(1, max(0, raw))
        let statusKey = "\(status)|\(currentFile ?? "")|\(bytesDownloaded)|\(expectedBytes)"
        // ~0.1% steps so multi‑GB transfers feel alive without flooding SwiftUI.
        let fractionMoved = value >= 1 || value >= lastEmitted + 0.001 || lastEmitted < 0
        let statusMoved = statusKey != lastStatusKey
        guard force || fractionMoved || statusMoved else { return }
        lastEmitted = value
        lastStatusKey = statusKey

        let step: String
        if value >= 1 {
            step = "Ready"
        } else if let file = currentFile, !file.isEmpty {
            step = "Downloading \(file)…"
        } else {
            step = status
        }

        emit(LocalMetalDownloadProgress(
            fraction: value,
            status: step,
            bytesDownloaded: bytesDownloaded > 0 ? bytesDownloaded : nil,
            bytesTotal: expectedBytes > 0 ? expectedBytes : nil,
            file: currentFile
        ))
    }

    static func fraction(from progress: Progress) -> Double {
        let hierarchical = progress.fractionCompleted
        if hierarchical.isFinite, hierarchical > 0 {
            return min(0.99, max(0, hierarchical))
        }
        if progress.totalUnitCount > 0, progress.completedUnitCount > 0 {
            return min(
                0.99,
                max(0, Double(progress.completedUnitCount) / Double(progress.totalUnitCount))
            )
        }
        if progress.completedUnitCount > 0 {
            // Indeterminate total — soft estimate from completed units (often bytes).
            return min(0.99, Double(progress.completedUnitCount) / 4_000_000_000)
        }
        return 0
    }

    /// Human step label from Foundation Progress (file counts / descriptions).
    static func statusLabel(from progress: Progress) -> String? {
        if progress.totalUnitCount > 0,
           progress.totalUnitCount <= 10_000,
           progress.completedUnitCount >= 0 {
            // Small unit counts usually mean file counts, not bytes.
            let done = progress.completedUnitCount
            let total = progress.totalUnitCount
            if total > 1 {
                return "Downloading files… \(done)/\(total)"
            }
        }
        if let extra = progress.localizedAdditionalDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !extra.isEmpty {
            return extra
        }
        if let desc = progress.localizedDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty,
           !desc.lowercased().contains("completed") {
            return desc
        }
        return nil
    }

    static func fileLabel(from progress: Progress) -> String? {
        if let url = progress.fileURL {
            let name = url.lastPathComponent
            if !name.isEmpty { return name }
        }
        if let url = progress.userInfo[ProgressUserInfoKey.fileURLKey] as? URL {
            let name = url.lastPathComponent
            if !name.isEmpty { return name }
        }
        return nil
    }
}

// MARK: - Container cache

private actor ContainerCache {
    private var containers: [String: ModelContainer] = [:]
    /// In-flight loads so concurrent callers await the same Task (no double RAM).
    private var inflight: [String: Task<ModelContainer, Error>] = [:]

    func get(_ id: String) -> ModelContainer? { containers[id] }

    func set(_ id: String, _ container: ModelContainer) {
        containers[id] = container
    }

    func remove(_ id: String) {
        inflight[id]?.cancel()
        inflight.removeValue(forKey: id)
        containers.removeValue(forKey: id)
    }

    func removeAll() {
        for task in inflight.values { task.cancel() }
        inflight.removeAll()
        containers.removeAll()
    }

    func ids() -> [String] {
        Array(containers.keys).sorted()
    }

    /// Load once per id; concurrent callers share the same task and result.
    func getOrLoad(
        id: String,
        load: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> ModelContainer,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
        if let cached = containers[id] {
            progress(1)
            return cached
        }
        if let existing = inflight[id] {
            return try await existing.value
        }

        let task = Task<ModelContainer, Error> {
            try await load(progress)
        }
        inflight[id] = task
        do {
            let container = try await task.value
            containers[id] = container
            inflight[id] = nil
            return container
        } catch {
            inflight[id] = nil
            throw error
        }
    }
}

// MARK: - Store sync helpers (avoid actor hop for lazy hub cache path)

extension LocalMetalModelStore {
    /// Nonisolated path resolution for hub cache (used from engine init).
    ///
    /// Prefer the canonical `CodeSocket` tree so downloads match
    /// `LocalMetalModelStore` inventory. If only the pre-rebrand
    /// `AnyProvCode` cache has weights, keep using it so existing
    /// downloads stay visible (Vision + chat).
    nonisolated func hubCacheDirectorySync() throws -> URL {
        let canonical = try LocalMetalPaths.hubCacheDirectory()
        // Prefer legacy only when it already has usable model trees and the
        // canonical cache is empty — avoids splitting new downloads.
        if let legacy = LocalMetalPaths.legacyHubCacheDirectoryIfPresent(),
           Self.hubCacheLooksPopulated(legacy),
           !Self.hubCacheLooksPopulated(canonical) {
            return legacy
        }
        return canonical
    }

    /// True when a hub-cache root has at least one `models--*` tree that looks complete.
    nonisolated private static func hubCacheLooksPopulated(_ root: URL) -> Bool {
        guard let kids = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        return kids.contains {
            $0.lastPathComponent.hasPrefix("models--")
                && LocalMetalModelStore.hasUsableModelCache(at: $0)
        }
    }
}
