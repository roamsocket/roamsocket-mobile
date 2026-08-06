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
    ///
    /// Does **not** leave the model resident in RAM — call `loadIntoMemory`
    /// when the user selects it in the model picker.
    func downloadModel(
        modelID: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Load weights into RAM for chat. Idempotent if already loaded.
    /// Progress is 0…1 while reading from disk / finishing any missing files.
    func loadIntoMemory(
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

    private let downloadedIDsKey = "localMetal.downloadedHubIDs.v1"

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

    /// Record a successful download so the UI / picker stay in sync even when
    /// HF hub layout detection is flaky (symlinks / partial path layouts).
    public func markDownloaded(modelID: String) {
        var ids = knownDownloadedIDs()
        ids.insert(modelID)
        UserDefaults.standard.set(Array(ids).sorted(), forKey: downloadedIDsKey)
    }

    public func markDeleted(modelID: String) {
        var ids = knownDownloadedIDs()
        ids.remove(modelID)
        UserDefaults.standard.set(Array(ids).sorted(), forKey: downloadedIDsKey)
    }

    public func knownDownloadedIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: downloadedIDsKey) ?? [])
    }

    /// Total bytes used by on-device model caches (hub + local folders).
    public func totalStorageBytes() -> Int64 {
        var total: Int64 = 0
        if let root = try? modelsDirectory() {
            total += directoryByteSize(root)
        }
        return total
    }

    /// Whether a hub model id has a usable snapshot on disk (config + weights).
    public func isDownloaded(modelID: String) async -> Bool {
        let onDisk = isDownloadedOnDisk(modelID: modelID)

        // Persisted success only counts when the cache still looks complete.
        // Never treat “folder exists” alone as ready (partial trees / wiped weights).
        if knownDownloadedIDs().contains(modelID) {
            if onDisk { return true }
            // Stale mark — incomplete, wiped, or prior loose heuristic.
            markDeleted(modelID: modelID)
        }

        if let engine = LocalMetalRuntime.engine {
            let ready = await engine.isDownloaded(modelID: modelID)
            if ready {
                // Only persist when disk also verifies (engine may report in-RAM only).
                if onDisk { markDownloaded(modelID: modelID) }
                return true
            }
        }

        if onDisk {
            markDownloaded(modelID: modelID)
            return true
        }
        return false
    }

    /// Disk-only check (no engine required) — looks for HF hub layout under our cache.
    public func isDownloadedOnDisk(modelID: String) -> Bool {
        if let repoDir = repoDirectory(for: modelID),
           Self.hasUsableModelCache(at: repoDir) {
            return true
        }
        if let root = try? modelsDirectory() {
            let leaf = modelID.split(separator: "/").last.map(String.init) ?? modelID
            let local = root.appendingPathComponent(leaf, isDirectory: true)
            if Self.hasUsableModelCache(at: local) { return true }
            if modelID.hasPrefix("local/") {
                let name = String(modelID.dropFirst("local/".count))
                let folder = root.appendingPathComponent(name, isDirectory: true)
                return Self.hasUsableModelCache(at: folder)
            }
        }
        return false
    }

    /// Models available for chat: any downloaded hub tree + user-copied folders.
    public func listModels() async -> [AIModel] {
        var out: [AIModel] = []
        var seen = Set<String>()

        func appendModel(hubID: String, displayName: String, context: Int? = 8192) {
            guard seen.insert(hubID).inserted else { return }
            out.append(AIModel(
                provider: .localMetal,
                modelID: hubID,
                displayName: displayName + " · Metal",
                contextWindow: context
            ))
        }

        // Scan HF hub cache for anything already downloaded (not limited to static catalog).
        if let cacheRoot = try? hubCacheDirectory(),
           let kids = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
           ) {
            for url in kids {
                guard url.lastPathComponent.hasPrefix("models--"),
                      Self.hasUsableModelCache(at: url),
                      let hubID = Self.hubID(fromRepoFolder: url.lastPathComponent)
                else { continue }
                markDownloaded(modelID: hubID)
                let pretty = LocalMetalCatalog.displayName(for: hubID)
                appendModel(hubID: hubID, displayName: pretty)
            }
        }

        // Persisted downloads (covers edge cases where blob layout is incomplete to scan).
        for hubID in knownDownloadedIDs() {
            guard seen.insert(hubID).inserted else { continue }
            // Require a complete cache (config + real weights), not just a leftover folder.
            var ready = isDownloadedOnDisk(modelID: hubID)
            if !ready, let engine = LocalMetalRuntime.engine {
                ready = await engine.isDownloaded(modelID: hubID) && isDownloadedOnDisk(modelID: hubID)
            }
            guard ready else {
                markDeleted(modelID: hubID)
                seen.remove(hubID)
                continue
            }
            appendModel(hubID: hubID, displayName: LocalMetalCatalog.displayName(for: hubID))
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
            guard ready else {
                seen.remove(entry.hubID)
                continue
            }
            markDownloaded(modelID: entry.hubID)
            appendModel(hubID: entry.hubID, displayName: LocalMetalCatalog.displayName(for: entry.hubID))
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
                      Self.hasUsableModelCache(at: url)
                else { continue }
                let id = "local/\(url.lastPathComponent)"
                let pretty = LocalMetalCatalog.displayName(for: id)
                appendModel(hubID: id, displayName: pretty, context: nil)
            }
        }
        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Approximate byte size of a cached model (best-effort).
    public func approximateByteSize(modelID: String) -> Int64? {
        if let repoDir = repoDirectory(for: modelID),
           FileManager.default.fileExists(atPath: repoDir.path) {
            let size = directoryByteSize(repoDir)
            if size > 0 { return size }
        }
        if modelID.hasPrefix("local/"), let root = try? modelsDirectory() {
            let name = String(modelID.dropFirst("local/".count))
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let size = directoryByteSize(folder)
            if size > 0 { return size }
        }
        return nil
    }

    // MARK: - Paths

    private func repoDirectory(for modelID: String) -> URL? {
        guard let cacheRoot = try? hubCacheDirectory() else { return nil }
        let folderName = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        return cacheRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: - Detection

    /// `models--org--name` → `org/name` (only first `--` is the org separator).
    public static func hubID(fromRepoFolder name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        let raw = String(name.dropFirst("models--".count))
        guard let range = raw.range(of: "--") else { return nil }
        let org = String(raw[..<range.lowerBound])
        let repo = String(raw[range.upperBound...])
        guard !org.isEmpty, !repo.isEmpty else { return nil }
        return "\(org)/\(repo)"
    }

    /// True when a HF hub repo folder (or flat model dir) looks download-complete.
    ///
    /// Requires config **and** at least one real weight file name (not index-only,
    /// not “blobs exist” alone). Handles the Python-compatible layout:
    /// `blobs/` + `snapshots/<rev>/` named symlinks.
    public static func hasUsableModelCache(at root: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return false }

        // Flat / local trees: config + weight files at any depth.
        if hasConfigAndWeightNames(at: root) { return true }

        // HF hub layout: named files live under snapshots/<rev>/ (often symlinks → blobs/).
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        guard fm.fileExists(atPath: snapshots.path),
              let revs = try? fm.contentsOfDirectory(
                at: snapshots,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return false }

        for rev in revs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rev.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if hasConfigAndWeightNames(at: rev) { return true }
        }
        return false
    }

    private static func hasConfigAndWeightNames(at root: URL) -> Bool {
        let fm = FileManager.default
        // Include symlinks by filename (HF snapshots → blobs).
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        var hasConfig = false
        var hasWeights = false
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            if name == "config.json" || name == "model_index.json" || name == "params.json" {
                hasConfig = true
            }
            // Index manifests alone are not weights — require real shards / single files.
            if name.hasSuffix(".safetensors.index.json")
                || name.hasSuffix(".npz.index.json") {
                continue
            }
            if name.hasSuffix(".safetensors")
                || name.hasSuffix(".npz")
                || name.hasSuffix(".gguf")
                || name.hasSuffix(".mlx") {
                hasWeights = true
            }
            if hasConfig && hasWeights { return true }
        }
        return false
    }

    private func directoryByteSize(_ url: URL) -> Int64 {
        Self.directoryByteSizeStatic(url)
    }

    private static func directoryByteSizeStatic(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              )
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            // Count regular files; for symlinks, count the destination when possible.
            if let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]) {
                if values.isSymbolicLink == true {
                    if let dest = try? fm.destinationOfSymbolicLink(atPath: fileURL.path) {
                        let destURL: URL
                        if (dest as NSString).isAbsolutePath {
                            destURL = URL(fileURLWithPath: dest)
                        } else {
                            destURL = fileURL.deletingLastPathComponent().appendingPathComponent(dest)
                        }
                        if let size = try? destURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                            total += Int64(size)
                        }
                    }
                    continue
                }
                if values.isRegularFile == true, let size = values.fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }
}
