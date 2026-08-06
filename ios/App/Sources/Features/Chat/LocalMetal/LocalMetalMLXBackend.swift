import Foundation
import AnyProvCore
import MLX
import MLXLLM
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
        let dir = (try? LocalMetalModelStore.shared.hubCacheDirectorySync())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("AnyProvCode-hf", isDirectory: true)
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

        // Lazy fallback if selection preload hasn't finished yet.
        let container = try await loadContainer(id: modelID, keepInMemory: true, progress: { _ in })
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
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Disk-only hub snapshot — do **not** load into MLX here. Loading via
        // `loadContainer` previously hid real byte progress (UI stuck ~2–4% while
        // large weights transferred, then jumped to 100% after load finished).
        if modelID.hasPrefix("local/") {
            progress(1)
            await LocalMetalModelStore.shared.markDownloaded(modelID: modelID)
            return
        }

        guard let repoID = Repo.ID(rawValue: modelID) else {
            throw ProviderError.transport("Invalid model id “\(modelID)”.")
        }

        progress(0)

        let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        let broker = DownloadProgressBroker(emit: progress)

        // Expected size from the hub tree so we can report true byte progress even
        // when Foundation Progress freezes mid-file (common with hierarchical Progress
        // updated off the main thread) and while URLSession stages data in tmp/.
        if let expected = try? await Self.expectedDownloadBytes(
            hubClient: hubClient,
            repoID: repoID,
            patterns: Self.modelDownloadPatterns
        ), expected > 0 {
            await broker.setExpectedBytes(expected)
        }

        // Seed UI from anything already cached (resume / retry).
        await broker.noteDiskBytes(
            cacheBytes: Self.directoryByteSize(at: repoDir),
            stagingBytes: 0
        )

        // Poll only this repo tree (blobs / incomplete / snapshots). Avoid scanning
        // shared app temp — other URLSession traffic inflated progress.
        let diskPoll = Task {
            while !Task.isCancelled {
                let cacheBytes = Self.directoryByteSize(at: repoDir)
                await broker.noteDiskBytes(cacheBytes: cacheBytes, stagingBytes: 0)
                try? await Task.sleep(nanoseconds: 200_000_000) // 5 Hz
            }
        }

        do {
            // Same patterns mlx-swift-lm uses for chat weights + tokenizer.
            _ = try await hubClient.downloadSnapshot(
                of: repoID,
                revision: "main",
                matching: Self.modelDownloadPatterns,
                progressHandler: { @MainActor p in
                    Task { await broker.noteHubProgress(p) }
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
        _ = try await loadContainer(id: modelID, keepInMemory: true, progress: progress)
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
        let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        if FileManager.default.fileExists(atPath: repoDir.path) {
            try FileManager.default.removeItem(at: repoDir)
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
        // Fallback: disk scan via store (same app-support root).
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
                // When weights are already on disk this mainly reports residual hub work;
                // `downloadModel` owns smooth download progress separately.
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

        private static func sumRegularFileBytes(at root: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
                options: [.skipsPackageDescendants]
              )
        else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += fileByteSize(fileURL)
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

/// Merges Hugging Face `Progress` with on-disk + tmp staging growth into a monotonic 0…1.
///
/// Hub `Progress` often only ticks when each file finishes (small JSON first → a few
/// percent), then freezes while multi‑GB weights stream into a temp file. We estimate
/// progress as `(cacheBytes + stagingBytes) / expectedBytes` so the bar keeps moving.
private actor DownloadProgressBroker {
    private let emit: @Sendable (Double) -> Void
    private var bestFraction: Double = 0
    private var expectedBytes: Int64 = 0
    private var lastEmitted: Double = -1

    init(emit: @escaping @Sendable (Double) -> Void) {
        self.emit = emit
    }

    func setExpectedBytes(_ bytes: Int64) {
        expectedBytes = max(expectedBytes, bytes)
    }

    func noteHubProgress(_ progress: Progress) {
        if progress.totalUnitCount > 1_024 {
            expectedBytes = max(expectedBytes, progress.totalUnitCount)
        }
        raise(Self.fraction(from: progress))
    }

    func noteDiskBytes(cacheBytes: Int64, stagingBytes: Int64) {
        guard expectedBytes > 1_024 else { return }
        let received = max(0, cacheBytes) + max(0, stagingBytes)
        raise(min(0.99, Double(received) / Double(expectedBytes)))
    }

    func finish() {
        publish(1)
    }

    private func raise(_ value: Double) {
        let clamped = min(0.99, max(0, value))
        guard clamped > bestFraction else { return }
        bestFraction = clamped
        publish(bestFraction)
    }

    private func publish(_ raw: Double) {
        let value = min(1, max(0, raw))
        // Emit on meaningful steps so SwiftUI isn't flooded, but stay responsive.
        guard value >= 1 || value >= lastEmitted + 0.005 || lastEmitted < 0 else { return }
        lastEmitted = value
        emit(value)
    }

    static func fraction(from progress: Progress) -> Double {
        if progress.totalUnitCount > 0 {
            let hierarchical = progress.fractionCompleted
            if hierarchical.isFinite, hierarchical > 0 {
                return min(0.99, max(0, hierarchical))
            }
            // Parent `completedUnitCount` is often 0 with child Progress units;
            // still try the ratio when the parent units are updated directly.
            if progress.completedUnitCount > 0 {
                return min(
                    0.99,
                    max(0, Double(progress.completedUnitCount) / Double(progress.totalUnitCount))
                )
            }
        } else if progress.completedUnitCount > 0 {
            // Indeterminate total — soft estimate from bytes written.
            return min(0.99, Double(progress.completedUnitCount) / 1_000_000_000)
        }
        return 0
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
    nonisolated func hubCacheDirectorySync() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base
            .appendingPathComponent("AnyProvCode/LocalModels/hf-hub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
