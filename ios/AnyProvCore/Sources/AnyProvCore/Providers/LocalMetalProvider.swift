import Foundation

/// On-device Metal (MLX) chat on the **phone**.
///
/// Models are **never bundled** in the app. Users download weights on demand
/// (Settings → On-device (Metal)); generation uses a process-wide engine the
/// app registers at launch (`LocalMetalRuntime`). Coding sessions list Metal
/// from the paired **desktop** (`GET /metal/models`) instead of this store.
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

// MARK: - Download progress (mirrors desktop MetalDownloadProgress)

/// Structured progress for on-device Metal model downloads.
/// Status strings are step-oriented (“Listing files…”, “Downloading weights…”)
/// so the UI can show the same multi-step detail as the desktop manage-models view.
public struct LocalMetalDownloadProgress: Sendable, Equatable {
    public var fraction: Double
    public var status: String
    public var bytesDownloaded: Int64?
    public var bytesTotal: Int64?
    public var file: String?

    public init(
        fraction: Double,
        status: String,
        bytesDownloaded: Int64? = nil,
        bytesTotal: Int64? = nil,
        file: String? = nil
    ) {
        self.fraction = fraction
        self.status = status
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
        self.file = file
    }

    /// 0…100 integer percent for compact labels.
    public var percent: Int {
        Int((min(1, max(0, fraction)) * 100).rounded(.down))
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
    /// Reports step status + byte-weighted fraction. Throws if the download fails.
    ///
    /// Does **not** leave the model resident in RAM — call `loadIntoMemory`
    /// when the user selects it in the model picker.
    func downloadModel(
        modelID: String,
        progress: @escaping @Sendable (LocalMetalDownloadProgress) -> Void
    ) async throws

    /// Load weights into RAM for chat. Idempotent if already loaded.
    /// Progress is 0…1 while reading from disk / finishing any missing files.
    func loadIntoMemory(
        modelID: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Remove cached weights for a model id (frees disk). No-op if not present.
    func deleteModel(modelID: String) async throws

    /// Drop the "verified complete" sentinel for a model without touching the
    /// hub cache on disk. Use when retrying / resuming a download so a stale
    /// flag from a prior session does not let a partial cache look usable.
    func invalidateVerifiedSentinel(modelID: String) async

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

// MARK: - On-disk paths

/// Application Support roots for phone Metal weights.
///
/// Canonical root is `RoamSocket/LocalModels`. Pre-rebrand builds wrote to
/// `AnyProvCode/LocalModels` — that legacy tree is still **scanned** so
/// downloads remain visible after the rename (Vision + chat pickers).
public enum LocalMetalPaths {
    /// Current app-support relative root for on-device models.
    public static let relativeRoot = "RoamSocket/LocalModels"
    /// Pre-rebrand root (still scanned for existing downloads).
    public static let legacyRelativeRoot = "AnyProvCode/LocalModels"

    /// Application Support directory (created if needed).
    public static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// Canonical models root (created).
    public static func modelsDirectory() throws -> URL {
        let dir = try applicationSupportDirectory()
            .appendingPathComponent(relativeRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Canonical HF hub cache (created). Engine downloads must use this path.
    public static func hubCacheDirectory() throws -> URL {
        let dir = try modelsDirectory().appendingPathComponent("hf-hub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Legacy models root if it exists (not created).
    public static func legacyModelsDirectoryIfPresent() -> URL? {
        guard let base = try? applicationSupportDirectory() else { return nil }
        let dir = base.appendingPathComponent(legacyRelativeRoot, isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Legacy HF hub cache if present (not created).
    public static func legacyHubCacheDirectoryIfPresent() -> URL? {
        guard let root = legacyModelsDirectoryIfPresent() else { return nil }
        let dir = root.appendingPathComponent("hf-hub", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// All hub-cache roots to scan (canonical first, then legacy).
    public static func hubCacheRootsToScan() -> [URL] {
        var roots: [URL] = []
        if let canonical = try? hubCacheDirectory() {
            roots.append(canonical)
        }
        if let legacy = legacyHubCacheDirectoryIfPresent(),
           !roots.contains(where: { $0.standardizedFileURL == legacy.standardizedFileURL }) {
            roots.append(legacy)
        }
        return roots
    }

    /// Repo folder name for a hub id: `org/name` → `models--org--name`.
    public static func hubRepoFolderName(for modelID: String) -> String {
        "models--" + modelID.replacingOccurrences(of: "/", with: "--")
    }
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
        try LocalMetalPaths.modelsDirectory()
    }

    /// Hugging Face hub cache root used by the MLX downloader (app-scoped).
    public func hubCacheDirectory() throws -> URL {
        try LocalMetalPaths.hubCacheDirectory()
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
        // Include legacy pre-rebrand cache so Settings storage matches inventory.
        if let legacy = LocalMetalPaths.legacyModelsDirectoryIfPresent() {
            total += directoryByteSize(legacy)
        }
        return total
    }

    /// Whether a hub model id has a usable snapshot on disk (config + weights).
    public func isDownloaded(modelID: String) async -> Bool {
        // Migrate known-complete pre-sentinel downloads before the stricter
        // disk check removes them.
        if knownDownloadedIDs().contains(modelID) {
            Self.migrateVerifiedSentinelIfNeeded(for: modelID)
        }

        let onDisk = isDownloadedOnDisk(modelID: modelID)

        // Persisted success only counts when the cache still looks complete.
        // Never treat “folder exists” alone as ready (partial trees / wiped weights).
        if knownDownloadedIDs().contains(modelID) {
            if onDisk {
                return true
            }
            // Engine may still see weights (e.g. legacy path) even when the
            // canonical scan is empty — do not wipe the mark until both fail.
            if let engine = LocalMetalRuntime.engine, await engine.isDownloaded(modelID: modelID) {
                markDownloaded(modelID: modelID)
                return true
            }
            markDeleted(modelID: modelID)
        }

        if let engine = LocalMetalRuntime.engine {
            let ready = await engine.isDownloaded(modelID: modelID)
            if ready {
                markDownloaded(modelID: modelID)
                return true
            }
        }

        if onDisk {
            markDownloaded(modelID: modelID)
            return true
        }
        return false
    }

    /// Disk-only check (no engine required) — looks for HF hub layout under our
    /// canonical cache **and** the pre-rebrand `AnyProvCode` tree.
    public func isDownloadedOnDisk(modelID: String) -> Bool {
        for repoDir in repoDirectories(for: modelID) {
            if Self.hasUsableModelCache(at: repoDir) { return true }
        }
        let roots = modelsRootsToScan()
        let leaf = modelID.split(separator: "/").last.map(String.init) ?? modelID
        for root in roots {
            let local = root.appendingPathComponent(leaf, isDirectory: true)
            if Self.hasUsableModelCache(at: local) { return true }
            if modelID.hasPrefix("local/") {
                let name = String(modelID.dropFirst("local/".count))
                let folder = root.appendingPathComponent(name, isDirectory: true)
                if Self.hasUsableModelCache(at: folder) { return true }
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

        // Scan HF hub caches (canonical RoamSocket + legacy AnyProvCode).
        for cacheRoot in LocalMetalPaths.hubCacheRootsToScan() {
            guard let kids = try? FileManager.default.contentsOfDirectory(
                at: cacheRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
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
            // Accept disk **or** engine (engine may resolve legacy path / in-RAM).
            var ready = isDownloadedOnDisk(modelID: hubID)
            if !ready, let engine = LocalMetalRuntime.engine {
                ready = await engine.isDownloaded(modelID: hubID)
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
            if isDownloadedOnDisk(modelID: entry.hubID) {
                ready = true
            } else if let engine = LocalMetalRuntime.engine {
                ready = await engine.isDownloaded(modelID: entry.hubID)
            } else {
                ready = false
            }
            guard ready else {
                seen.remove(entry.hubID)
                continue
            }
            markDownloaded(modelID: entry.hubID)
            appendModel(hubID: entry.hubID, displayName: LocalMetalCatalog.displayName(for: entry.hubID))
        }

        // User-copied MLX trees under LocalModels (not hf-hub), both path roots.
        for dir in modelsRootsToScan() {
            guard let kids = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
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
        for repoDir in repoDirectories(for: modelID) {
            if FileManager.default.fileExists(atPath: repoDir.path) {
                let size = directoryByteSize(repoDir)
                if size > 0 { return size }
            }
        }
        if modelID.hasPrefix("local/") {
            let name = String(modelID.dropFirst("local/".count))
            for root in modelsRootsToScan() {
                let folder = root.appendingPathComponent(name, isDirectory: true)
                let size = directoryByteSize(folder)
                if size > 0 { return size }
            }
        }
        return nil
    }

    // MARK: - Paths

    /// Canonical + legacy model roots that exist (canonical always created first).
    private func modelsRootsToScan() -> [URL] {
        var roots: [URL] = []
        if let canonical = try? modelsDirectory() {
            roots.append(canonical)
        }
        if let legacy = LocalMetalPaths.legacyModelsDirectoryIfPresent(),
           !roots.contains(where: { $0.standardizedFileURL == legacy.standardizedFileURL }) {
            roots.append(legacy)
        }
        return roots
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

    /// Sentinel written after a successful verified download of a hub model.
    /// Prevents interrupted downloads (which may already have config + partial
    /// weights) from being treated as complete.
    public static let verifiedSentinelName = ".roamsocket-verified"

    public static func hasVerifiedSentinel(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(verifiedSentinelName).path)
    }

    public static func touchVerifiedSentinel(at root: URL) {
        let url = root.appendingPathComponent(verifiedSentinelName)
        try? Data().write(to: url, options: .atomic)
    }

    public static func removeVerifiedSentinel(at root: URL) {
        let url = root.appendingPathComponent(verifiedSentinelName)
        try? FileManager.default.removeItem(at: url)
    }

    /// True when a HF hub repo folder (or flat model dir) looks download-complete.
    ///
    /// Requires config **and** at least one real weight file name (not index-only,
    /// not “blobs exist” alone). Handles the Python-compatible layout:
    /// `blobs/` + `snapshots/<rev>/` named symlinks.
    ///
    /// For HF hub layouts we also require the `verifiedSentinelName` sentinel,
    /// because interrupted downloads can leave config + partial weights looking
    /// complete by filename alone.
    public static func hasUsableModelCache(at root: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return false }

        // HF hub layout is identified by a `snapshots/` directory. Require a
        // verified sentinel so interrupted downloads are not treated as complete.
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        let isHubLayout = fm.fileExists(atPath: snapshots.path)
        if isHubLayout, !hasVerifiedSentinel(at: root) { return false }

        // Flat / local trees: config + weight files at any depth.
        if hasConfigAndWeightNames(at: root) { return true }

        // HF hub layout: named files live under snapshots/<rev>/ (often symlinks → blobs/).
        guard isHubLayout,
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

    /// One-time migration: pre-sentinel hub downloads that are known-complete
    /// get the sentinel so they remain usable after the stricter check.
    private static func migrateVerifiedSentinelIfNeeded(for modelID: String) {
        for repoDir in Self.repoDirectoriesStatic(for: modelID) {
            guard hasConfigAndWeightNames(at: repoDir) else { continue }
            touchVerifiedSentinel(at: repoDir)
        }
    }

    private func repoDirectories(for modelID: String) -> [URL] {
        Self.repoDirectoriesStatic(for: modelID)
    }

    private static func repoDirectoriesStatic(for modelID: String) -> [URL] {
        let folderName = LocalMetalPaths.hubRepoFolderName(for: modelID)
        return LocalMetalPaths.hubCacheRootsToScan().map {
            $0.appendingPathComponent(folderName, isDirectory: true)
        }
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
