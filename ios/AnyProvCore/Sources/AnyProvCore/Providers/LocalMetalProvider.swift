import Foundation

/// Chat-only on-device inference via Metal (MLX).
///
/// Models are **never bundled** in the app. Users download weights on demand
/// (Settings → On-device (Metal)); generation uses a process-wide engine the
/// app registers at launch (`LocalMetalRuntime`). Coding sessions never use
/// this provider (`supportsCodingAgent == false`).
public struct LocalMetalProvider: ModelProvider {
    public let id: ProviderID = .localMetal

    public init() {}

    public func listModels(apiKey: String) async throws -> [AIModel] {
        await LocalMetalModelStore.shared.listModels()
    }

    public func chat(
        model: String,
        apiKey: String,
        messages: [ProviderChatMessage],
        effort: Effort?
    ) async throws -> String {
        guard let engine = LocalMetalRuntime.engine else {
            throw ProviderError.transport(
                "On-device Metal runtime is not ready. Rebuild the app so the MLX backend is linked, then open Settings → On-device (Metal) and download a model."
            )
        }
        return try await engine.generate(modelID: model, messages: messages, effort: effort)
    }
}

// MARK: - Runtime registration (app injects MLX implementation)

/// Engine the app registers at launch (MLX-backed).
public protocol LocalMetalGenerating: Sendable {
    func generate(
        modelID: String,
        messages: [ProviderChatMessage],
        effort: Effort?
    ) async throws -> String

    /// Download weights for a catalog model id into the app’s on-device cache.
    /// Progress is 0…1. Throws if the download fails.
    func downloadModel(
        modelID: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Remove cached weights for a model id (frees disk). No-op if not present.
    func deleteModel(modelID: String) async throws

    /// Drop a loaded model from RAM (keeps disk weights). Call when free memory.
    func unloadFromMemory(modelID: String) async

    /// Drop every in-memory model container and clear the MLX cache.
    func unloadAllFromMemory() async

    /// Whether weights for this hub id are present in the on-device cache.
    func isDownloaded(modelID: String) async -> Bool

    /// Whether this model is currently held in RAM.
    func isLoadedInMemory(modelID: String) async -> Bool

    /// Model ids currently resident in memory.
    func loadedModelIDs() async -> [String]
}

/// Process-wide hook so AnyProvCore stays free of the heavy MLX dependency graph.
public enum LocalMetalRuntime {
    public static var engine: (any LocalMetalGenerating)?

    /// True when the app has registered an MLX-backed engine.
    public static var isReady: Bool { engine != nil }
}

// MARK: - Model inventory

/// Catalog + on-disk inventory for **downloadable** Metal chat models.
///
/// Nothing is shipped inside the IPA. Weights live under Application Support
/// after the user taps Download.
public actor LocalMetalModelStore {
    public static let shared = LocalMetalModelStore()

    /// @available — prefer `LocalMetalCatalog.recommended` / `allEntries`.
    public static var catalogPresets: [(id: String, name: String, approxSize: String)] {
        LocalMetalCatalog.recommended.map { ($0.hubID, $0.displayName, $0.approxSize) }
    }

    /// Root for hub cache + optional user-copied trees.
    public func modelsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("AnyProvCode/LocalModels", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Hugging Face hub cache root used by the MLX downloader (app-scoped).
    public func hubCacheDirectory() throws -> URL {
        let dir = try modelsDirectory().appendingPathComponent("hf-hub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whether a hub model id has a usable snapshot on disk (config + weights).
    public func isDownloaded(modelID: String) async -> Bool {
        if let engine = LocalMetalRuntime.engine {
            return await engine.isDownloaded(modelID: modelID)
        }
        return isDownloadedOnDisk(modelID: modelID)
    }

    /// Disk-only check (no engine required) — looks for HF hub layout under our cache.
    public func isDownloadedOnDisk(modelID: String) -> Bool {
        guard let cacheRoot = try? hubCacheDirectory() else { return false }
        let folderName = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let repoDir = cacheRoot.appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: repoDir.path) else {
            if let root = try? modelsDirectory() {
                let leaf = modelID.split(separator: "/").last.map(String.init) ?? modelID
                let local = root.appendingPathComponent(leaf, isDirectory: true)
                return hasModelWeights(at: local)
            }
            return false
        }
        return hasModelWeights(at: repoDir)
    }

    /// Models available for chat: any downloaded hub tree + user-copied folders.
    public func listModels() async -> [AIModel] {
        var out: [AIModel] = []
        var seen = Set<String>()

        // Scan HF hub cache for anything already downloaded (not limited to static catalog).
        if let cacheRoot = try? hubCacheDirectory(),
           let kids = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
           ) {
            for url in kids {
                guard url.lastPathComponent.hasPrefix("models--"),
                      hasModelWeights(at: url)
                else { continue }
                // models--org--name → org/name
                let raw = String(url.lastPathComponent.dropFirst("models--".count))
                let hubID = raw.replacingOccurrences(of: "--", with: "/")
                guard seen.insert(hubID).inserted else { continue }
                let pretty = LocalMetalCatalog.recommended.first { $0.hubID == hubID }?.displayName
                    ?? LocalMetalCatalog.registry.first { $0.hubID == hubID }?.displayName
                    ?? hubID.split(separator: "/").last.map(String.init)
                    ?? hubID
                out.append(AIModel(
                    provider: .localMetal,
                    modelID: hubID,
                    displayName: pretty + " · Metal",
                    contextWindow: 8192
                ))
            }
        }

        // Also surface known catalog entries that report downloaded via engine.
        let catalog = await LocalMetalCatalog.shared.allEntries(preferFreshRemote: false)
        for entry in catalog {
            guard seen.insert(entry.hubID).inserted else { continue }
            let ready: Bool
            if let engine = LocalMetalRuntime.engine {
                ready = await engine.isDownloaded(modelID: entry.hubID)
            } else {
                ready = isDownloadedOnDisk(modelID: entry.hubID)
            }
            guard ready else { continue }
            out.append(AIModel(
                provider: .localMetal,
                modelID: entry.hubID,
                displayName: entry.displayName + " · Metal",
                contextWindow: 8192
            ))
        }

        // User-copied MLX trees under Application Support/LocalModels (not hf-hub).
        if let dir = try? modelsDirectory(),
           let kids = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
           ) {
            for url in kids {
                if url.lastPathComponent == "hf-hub" { continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue,
                      hasModelWeights(at: url)
                else { continue }
                let id = "local/\(url.lastPathComponent)"
                guard seen.insert(id).inserted else { continue }
                out.append(AIModel(
                    provider: .localMetal,
                    modelID: id,
                    displayName: url.lastPathComponent + " · Metal",
                    contextWindow: nil
                ))
            }
        }
        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Approximate byte size of a cached model (best-effort).
    public func approximateByteSize(modelID: String) -> Int64? {
        guard let cacheRoot = try? hubCacheDirectory() else { return nil }
        let folderName = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let repoDir = cacheRoot.appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: repoDir.path) else { return nil }
        return directoryByteSize(repoDir)
    }

    // MARK: - Private

    private func hasModelWeights(at root: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        var hasConfig = false
        var hasWeights = false
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            if name == "config.json" { hasConfig = true }
            if name.hasSuffix(".safetensors") || name.hasSuffix(".npz") { hasWeights = true }
            if hasConfig && hasWeights { return true }
        }
        return false
    }

    private func directoryByteSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }
}
