import Foundation
import CoreImage
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Metal)
import Metal
#endif
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
    ///
    /// No-op when `MetalDevice.canInitializeMLX` returns false (Simulator
    /// with a null Metal device name, iOS 26.5 SDK on Mac17,4-class
    /// hardware). In that case `shared` stays nil, every call site bails
    /// to cloud-provider chat, and the rest of the app boots normally.
    static func register() {
        guard MetalDevice.canInitializeMLX else { return }
        shared = Engine()
    }

    /// Non-nil after `register()` (or earlier in this process).
    static var shared: (any LocalMetalGenerating)?
}

// MARK: - Metal device probe

/// Cheap Metal probe that gates MLX initialization.
///
/// `mlx-swift` ships a Metal C++ layer that constructs
/// `std::basic_string(const char*)` from the Metal device's `name` during
/// `mlx_set_cache_limit`. On certain simulator runtimes (iOS 26.5 SDK on
/// Mac17,4-class Apple Silicon, observed) the C++ aborts with
/// `__libcpp_verbose_abort` and the entire process dies — Swift cannot
/// catch SIGABRT, so we have to skip the MLX call entirely. The probe
/// below looks at every Metal string/introspection the C++ layer is
/// likely to dereference and short-circuits when any of them looks bad.
///
/// iOS simulator detection is the only known failure; real iPhones,
/// iPads, and Macs always pass.
enum MetalDevice {
    /// True when MLX can be safely initialized on this device.
    static var canInitializeMLX: Bool {
        #if canImport(Metal)
        #if targetEnvironment(simulator)
        // Simulator-only MLX init is opt-in. The C++ Metal layer
        // hits an uncatchable `__libcpp_verbose_abort` inside
        // `mlx_set_cache_limit` on the iOS 26.5 sim (and likely later
        // runtimes) because the simulated `MTLDevice` stringifies to a
        // null pointer the C++ `basic_string` constructor refuses to
        // accept. We work around it by refusing to register the engine
        // when we're running under the simulator — cloud-provider chat
        // works fine, on-device VLM just becomes unavailable.
        return false
        #else
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        // Sanity check: real devices always have a non-empty name.
        if device.name.isEmpty { return false }
        return true
        #endif
        #else
        return false
        #endif
    }
}

// MARK: - Engine

private final class Engine: LocalMetalGenerating, @unchecked Sendable {
    private let cache = ContainerCache()

    private let hubCache: HubCache
    /// Hub client — metadata, listing, weight downloads, load-time fetches.
    /// Uses a normal foreground session: `HubClient` relies on completion-handler
    /// based async APIs that background `URLSession` configurations do not support
    /// (they crash with NSGenericException).
    private let hubClient: HubClient

    /// `true` while a `loadContainer` is in flight. The memory-warning
    /// observer checks this so it doesn't yank the weights out from under a
    /// load that's about to finish — iOS fires the warning *because* of the
    /// load, not because we have free RAM to reclaim.
    private let loadInFlight = LoadFlag()

    /// Wired-memory admission control. Tickets let MLX suspend an allocation
    /// when the device can't admit more instead of letting the process grow
    /// past iOS jetsam limits.
    private static let wiredTicket: MLX.WiredMemoryTicket = {
        // 4 GB reservation is enough for a Gemma 4 4-bit vision tower plus
        // its forward-pass scratch, but well under iOS jetsam thresholds on
        // 8 GB-class devices. Reservation tickets participate in admission
        // without keeping the wired limit elevated while idle.
        //
        // Module-qualified `MLX.WiredSumPolicy` because mlx-swift-lm
        // re-exports the type through multiple umbrella headers (MLXLLM,
        // MLXVLM, MLXLMCommon) and Swift's type-resolution path can't pick
        // a single symbol without an explicit module prefix.
        let policy: any WiredMemoryPolicy = MLX.WiredSumPolicy()
        return MLX.WiredMemoryTicket(
            size: 4 * 1024 * 1024 * 1024,
            policy: policy,
            kind: .reservation
        )
    }()

    init() {
        // Must match LocalMetalModelStore / LocalMetalPaths so downloads appear
        // in Settings, chat picker, and Vision. Falls back to legacy AnyProvCode
        // only when that tree already has weights (migration).
        let dir = (try? LocalMetalModelStore.shared.hubCacheDirectorySync())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("RoamSocket-hf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hubCache = HubCache(cacheDirectory: dir)
        self.hubCache = hubCache
        self.hubClient = HubClient(cache: hubCache)

        applySafeMemoryLimits()
    }

    /// Cap MLX's buffer cache + memory limit before any model load runs.
    ///
    /// Without these caps, MLX's pool grows unbounded up to Metal's
    /// `recommendedMaxWorkingSetSize` (often 6–8 GB on iPhone 16 Pro). That
    /// collides with iOS jetsam the moment we try to load a 5 GB VLM,
    /// especially with Xcode's MallocStackLogging overhead.
    ///
    /// - **Cache limit**: 64 MB. The docs explicitly recommend "small cache
    ///   sizes (e.g. 2 MB) perform just as well" for inference; 64 MB is
    ///   plenty of headroom for KV cache + intermediates.
    /// - **Memory limit**: half of Metal's recommended working set, floored
    ///   at 2 GB and capped at 4 GB. MLX's default is 1.5× the working set,
    ///   which is dangerously close to the iOS process limit.
    private func applySafeMemoryLimits() {
        // Cache: cap to 64 MB. The MLX docs call this out by name — buffer
        // pool size is independent of inference correctness.
        MLX.Memory.cacheLimit = 64 * 1024 * 1024

        // Memory: half of Metal's recommended working set, clamped.
        let workingSet = Self.metalRecommendedWorkingSetBytes()
        if workingSet > 0 {
            let target = max(2 * 1024 * 1024 * 1024, min(4 * 1024 * 1024 * 1024, workingSet / 2))
            MLX.Memory.memoryLimit = target
        }
    }

    /// Metal's `recommendedMaxWorkingSetSize`, or 0 if Metal is unavailable.
    /// On iPhone 16 Pro (8 GB) this is typically ~5.5 GB.
    private static func metalRecommendedWorkingSetBytes() -> Int {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return 0 }
        let value = device.recommendedMaxWorkingSetSize
        return value > 0 ? Int(value) : 0
        #else
        return 0
        #endif
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
        // Drive the factory off the model id, never off the message — a
        // text-only hub id must NEVER be loaded via VLMModelFactory, even
        // when the message has no images. Loading the wrong factory on a
        // multi-GB weight can crash the MLX runtime (e.g. Gemma 3n `-lm-`
        // text builds, plain Llama, etc.).
        let isVLM = Self.isLikelyVLM(modelID)
        if hasImages && !isVLM {
            throw ProviderError.transport(
                "This on-device model does not support vision. Download a Vision model (Gemma 4, Qwen2-VL, SmolVLM, …) from Settings → On-device (Metal)."
            )
        }

        // Lazy fallback if selection preload hasn't finished yet.
        let container = try await loadContainer(
            id: modelID,
            keepInMemory: true,
            preferVLM: isVLM,
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
                    // VLM forward passes are RAM-heavy. Clear Metal's
                    // intermediate buffer cache **before** decoding the
                    // images + running the forward pass — eviction after
                    // the fact is too late when we're already on the edge
                    // of the device's RAM budget (Xcode + MallocStackLogging
                    // + view-debugging dylib all add overhead on top of the
                    // resident multi-GB vision tower).
                    MLX.Memory.clearCache()
                    let images = try Self.userInputImages(from: last.images)
                    let prompt = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let output = try await session.respond(
                        to: prompt.isEmpty ? "Describe this image." : prompt,
                        images: images,
                        videos: [],
                        audios: []
                    )
                    // Post-forward cleanup: drop the Metal buffer cache AND
                    // evict this container so the next photo capture (or
                    // backgrounded app resuming) is not fighting a pinned
                    // multi-GB vision tower for memory.
                    MLX.Memory.clearCache()
                    await cache.remove(modelID)
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
            MLX.Memory.clearCache()
            throw error
        } catch is CancellationError {
            MLX.Memory.clearCache()
            throw CancellationError()
        } catch {
            MLX.Memory.clearCache()
            // VLM-specific failure: the vision tower tends to OOM before the
            // text-only path. Evict the container so we don't repeatedly crash
            // trying to feed it more images.
            await cache.remove(modelID)
            // A raw (non-transport, non-cancellation) failure means the runtime
            // itself blew up mid-generation (OOM, Metal shader error, …).
            // Persist a crash report so the next launch can offer the logs and
            // a re-download/delete path.
            await LocalMetalCrashStore.shared.record(
                modelID: modelID,
                displayName: LocalMetalCatalog.displayName(for: modelID),
                error: error.localizedDescription
            )
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

        // Catalog size first so multi‑GB models (Gemma E4B ~5.2 GB) show a real
        // total immediately — hub tree listing can take several seconds on cellular.
        let catalogBytes = Self.approxBytesFromCatalog(modelID: modelID)
        progress(LocalMetalDownloadProgress(
            fraction: 0,
            status: "Listing files…",
            bytesDownloaded: 0,
            bytesTotal: catalogBytes
        ))
        // Let SwiftUI paint the progress banner before hub I/O.
        await Task.yield()

        let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        let broker = DownloadProgressBroker(emit: progress)
        if let catalogBytes, catalogBytes > 0 {
            await broker.setExpectedBytes(catalogBytes)
        }

        // Expected size from the hub tree so we can report true byte progress even
        // when Foundation Progress freezes mid-file and while URLSession stages
        // multi‑GB weights in tmp/ before they land in the hub cache.
        // Cap wait so a hung listFiles cannot freeze the UI with no further updates.
        do {
            let expected = try await Self.expectedDownloadBytes(
                hubClient: hubClient,
                repoID: repoID,
                patterns: Self.modelDownloadPatterns,
                timeoutSeconds: 20
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
                progress(LocalMetalDownloadProgress(
                    fraction: 0,
                    status: "Preparing download…",
                    bytesDownloaded: 0,
                    bytesTotal: catalogBytes
                ))
            }
        } catch {
            // Tree size is optional; continue with catalog / hub Progress alone.
            progress(LocalMetalDownloadProgress(
                fraction: 0,
                status: "Preparing download…",
                bytesDownloaded: 0,
                bytesTotal: catalogBytes
            ))
        }

        // Baseline tmp occupancy so we only attribute *growth* to this download
        // (other URLSession traffic must not inflate the bar).
        let tmpBaseline = await Task.detached(priority: .utility) {
            Self.largeTempFileBytes()
        }.value
        await broker.setTempBaseline(tmpBaseline)

        // Seed UI from anything already cached (resume / retry).
        let initialCache = await Task.detached(priority: .utility) {
            Self.directoryByteSize(at: repoDir)
        }.value
        await broker.noteObservedBytes(
            cacheBytes: initialCache,
            tempBytes: tmpBaseline,
            status: initialCache > 1_048_576 ? "Resuming…" : "Downloading weights…"
        )

        // Poll cache + large temp files + last hub Progress at ~2.5 Hz.
        // (Was 10 Hz — full-tree walks of multi‑GB caches thrash the phone.)
        var diskPoll = Self.startDiskPoll(broker: broker, repoDir: repoDir)

        do {
            await broker.setStatus("Downloading weights…")
            // Foreground URLSession: `HubClient` uses completion-handler based
            // async APIs, which background URLSessions reject.
            //
            // IMPORTANT: progressHandler must NOT hop to MainActor. Hugging Face
            // fires it very frequently for multi‑GB weights; MainActor + SwiftUI
            // floods froze / jetsammed the app on Gemma E4B (~5 GB).
            _ = try await hubClient.downloadSnapshot(
                of: repoID,
                revision: "main",
                matching: Self.modelDownloadPatterns,
                // One large safetensors at a time is more reliable on phones.
                maxConcurrentDownloads: 1,
                progressHandler: { p in
                    Task(priority: .utility) {
                        await broker.noteHubProgress(p)
                    }
                }
            )
            diskPoll.cancel()
            _ = await diskPoll.result

            // Verify the snapshot is actually complete before declaring success.
            // Interrupted downloads can leave config + partial weights looking
            // complete to a simple filename check, which then fails at load time
            // with missing-key errors.
            await broker.setStatus("Verifying…")
            do {
                try await Self.verifyDownloadedFiles(
                    hubClient: hubClient,
                    repoID: repoID,
                    repoDir: repoDir,
                    patterns: Self.modelDownloadPatterns
                )
            } catch {
                // A verification failure after `downloadSnapshot` returns usually
                // means the network dropped before the final bytes were flushed.
                // Range-resume the partial blobs once automatically before giving up.
                await broker.setStatus("Resuming after incomplete verification…")
                diskPoll = Self.startDiskPoll(broker: broker, repoDir: repoDir)
                _ = try await hubClient.downloadSnapshot(
                    of: repoID,
                    revision: "main",
                    matching: Self.modelDownloadPatterns,
                    maxConcurrentDownloads: 1,
                    progressHandler: { p in
                        Task(priority: .utility) {
                            await broker.noteHubProgress(p)
                        }
                    }
                )
                diskPoll.cancel()
                _ = await diskPoll.result
                try await Self.verifyDownloadedFiles(
                    hubClient: hubClient,
                    repoID: repoID,
                    repoDir: repoDir,
                    patterns: Self.modelDownloadPatterns
                )
            }
            LocalMetalModelStore.touchVerifiedSentinel(at: repoDir)

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
        // Engine cache root (RoamSocket or legacy AnyProvCode, whichever we bind to).
        let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        LocalMetalModelStore.removeVerifiedSentinel(at: repoDir)
        if FileManager.default.fileExists(atPath: repoDir.path) {
            try FileManager.default.removeItem(at: repoDir)
        }
        // Also wipe the same hub id under every known app-support hub root so
        // split RoamSocket / AnyProvCode trees cannot leave orphan weights.
        let folderName = LocalMetalPaths.hubRepoFolderName(for: modelID)
        for root in LocalMetalPaths.hubCacheRootsToScan() {
            let extra = root.appendingPathComponent(folderName, isDirectory: true)
            if extra.standardizedFileURL != repoDir.standardizedFileURL,
               FileManager.default.fileExists(atPath: extra.path) {
                LocalMetalModelStore.removeVerifiedSentinel(at: extra)
                try? FileManager.default.removeItem(at: extra)
            }
        }
        await LocalMetalModelStore.shared.markDeleted(modelID: modelID)
    }

    func invalidateVerifiedSentinel(modelID: String) async {
        if modelID.hasPrefix("local/") {
            let name = String(modelID.dropFirst("local/".count))
            if let dir = try? await LocalMetalModelStore.shared.modelsDirectory() {
                LocalMetalModelStore.removeVerifiedSentinel(at: dir.appendingPathComponent(name, isDirectory: true))
            }
            return
        }
        guard let repoID = Repo.ID(rawValue: modelID) else { return }
        let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        LocalMetalModelStore.removeVerifiedSentinel(at: repoDir)
        // Same sweep as deleteModel, but leave the actual weights/blobs in
        // place so HubClient can Range-resume them on the next download.
        let folderName = LocalMetalPaths.hubRepoFolderName(for: modelID)
        for root in LocalMetalPaths.hubCacheRootsToScan() {
            let extra = root.appendingPathComponent(folderName, isDirectory: true)
            if extra.standardizedFileURL != repoDir.standardizedFileURL {
                LocalMetalModelStore.removeVerifiedSentinel(at: extra)
            }
        }
    }

    func unloadFromMemory(modelID: String) async {
        await cache.remove(modelID)
        // Free Metal/MLX intermediate buffers held by the runtime.
        MLX.Memory.clearCache()
    }

    func unloadAllFromMemory() async {
        await cache.removeAll()
        MLX.Memory.clearCache()
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
        guard let repoID = Repo.ID(rawValue: modelID) else { return false }
        let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        if LocalMetalModelStore.hasUsableModelCache(at: repoDir) { return true }
        // An in-memory container (recent load / just-finished download) only
        // counts while the weights are still usable on disk. A model whose
        // files were deleted must not keep reporting as downloaded — the chat
        // selector and Manage-models state both trust this check.
        if await cache.get(modelID) != nil {
            return await LocalMetalModelStore.shared.isDownloadedOnDisk(modelID: modelID)
        }
        // Fallback: store scans RoamSocket + legacy AnyProvCode trees.
        return await LocalMetalModelStore.shared.isDownloadedOnDisk(modelID: modelID)
    }

    func isLoadedInMemory(modelID: String) async -> Bool {
        await cache.get(modelID) != nil
    }

    func loadedModelIDs() async -> [String] {
        await cache.ids()
    }

    func isLoadInFlight() async -> Bool {
        await loadInFlight.get()
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

        // Mark the load as in-flight so the memory-warning observer doesn't
        // yank the model out from under us while the weights are still being
        // mmap'd. iOS fires `didReceiveMemoryWarning` *because* of the load,
        // not because we have free RAM to reclaim.
        await loadInFlight.set(true)
        defer {
            Task { [loadInFlight] in await loadInFlight.set(false) }
        }

        // Wired-memory admission: when a multi-GB load can't fit alongside
        // the rest of the app, MLX suspends instead of letting the process
        // grow past iOS jetsam limits. The reservation ticket also keeps
        // the limit from being clobbered by a concurrent download.
        //
        // Bind the closure result so `loadContainer`'s own return is
        // satisfied — the compiler can't see through `withWiredLimit`'s
        // closure to infer it.
        return try await MLX.WiredMemoryTicket.withWiredLimit(Self.wiredTicket) {
            try await loadContainerInner(
                id: id,
                keepInMemory: keepInMemory,
                preferVLM: preferVLM,
                progress: progress
            )
        }
    }

    private func loadContainerInner(
        id: String,
        keepInMemory: Bool,
        preferVLM: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
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
            // If loading failed, the cache may be incomplete/corrupted. Clear the
            // downloaded mark and verified sentinel so the user can re-download.
            if !id.hasPrefix("local/") {
                await LocalMetalModelStore.shared.markDeleted(modelID: id)
                if let repoID = Repo.ID(rawValue: id) {
                    let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
                    LocalMetalModelStore.removeVerifiedSentinel(at: repoDir)
                }
            }
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
        patterns: [String],
        timeoutSeconds: Double = 20
    ) async throws -> Int64 {
        let files = try await expectedDownloadFiles(
            hubClient: hubClient,
            repoID: repoID,
            patterns: patterns,
            timeoutSeconds: timeoutSeconds
        )
        return files.reduce(0) { $0 + $1.size }
    }

    /// List hub files we expect locally after a complete download.
    private static func expectedDownloadFiles(
        hubClient: HubClient,
        repoID: Repo.ID,
        patterns: [String],
        timeoutSeconds: Double = 20
    ) async throws -> [(path: String, size: Int64)] {
        try await withThrowingTaskGroup(of: [(path: String, size: Int64)].self) { group in
            group.addTask {
                let entries = try await hubClient.listFiles(
                    in: repoID,
                    kind: .model,
                    revision: "main",
                    recursive: true
                )
                return entries.compactMap { entry -> (path: String, size: Int64)? in
                    guard entry.type == .file else { return nil }
                    guard matchesGlobPatterns(entry.path, patterns: patterns) else { return nil }
                    return (entry.path, Int64(entry.size ?? 0))
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw CancellationError()
            }
            guard let first = try await group.next() else { return [] }
            group.cancelAll()
            return first
        }
    }

    /// Verify that every hub file we expect is present in the local snapshot(s)
    /// and, when the hub reports a size, that the on-disk size matches exactly.
    /// Follows HF symlinks so blob sizes are checked, not symlink sizes.
    private static func verifyDownloadedFiles(
        hubClient: HubClient,
        repoID: Repo.ID,
        repoDir: URL,
        patterns: [String]
    ) async throws {
        let expected = try await expectedDownloadFiles(
            hubClient: hubClient,
            repoID: repoID,
            patterns: patterns
        )
        guard !expected.isEmpty else {
            throw ProviderError.transport("Verification failed: no model files listed by Hugging Face.")
        }

        let fm = FileManager.default
        let snapshotsDir = repoDir.appendingPathComponent("snapshots", isDirectory: true)
        guard fm.fileExists(atPath: snapshotsDir.path) else {
            throw ProviderError.transport("Verification failed: no snapshot directory found after download.")
        }

        let revs = (try? fm.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        } ?? []

        var missing: [String] = []
        var wrongSize: [(path: String, expected: Int64, actual: Int64)] = []

        for (path, expectedSize) in expected {
            var found = false
            var actualIfExists: Int64 = 0
            for rev in revs {
                let candidate = rev.appendingPathComponent(path, isDirectory: false)
                guard fm.fileExists(atPath: candidate.path) else { continue }
                let actualSize = resolvedFileByteSize(at: candidate)
                actualIfExists = actualSize
                if expectedSize <= 0 || actualSize == expectedSize {
                    found = true
                    break
                }
            }
            if !found {
                if revs.isEmpty {
                    missing.append(path)
                } else {
                    // Determine whether it is missing or just the wrong size.
                    let anyExists = revs.contains { fm.fileExists(atPath: $0.appendingPathComponent(path).path) }
                    if anyExists {
                        wrongSize.append((path, expectedSize, actualIfExists))
                    } else {
                        missing.append(path)
                    }
                }
            }
        }

        guard missing.isEmpty, wrongSize.isEmpty else {
            let missingPart = missing.isEmpty ? nil : "missing \(missing.joined(separator: ", "))"
            let wrongSizePart = wrongSize.isEmpty ? nil : "wrong size " + wrongSize.map {
                "\($0.path) (got \($0.actual) B, expected \($0.expected) B)"
            }.joined(separator: ", ")
            let parts: [String] = [missingPart, wrongSizePart].compactMap { $0 }
            throw ProviderError.transport(
                "Download verification failed: \(parts.joined(separator: "; ")). " +
                "Retry to resume or delete the model and download again."
            )
        }
    }

    /// Size of a file, resolving HF symlinks to the underlying blob.
    ///
    /// Uses the **logical** file size (`URLResourceKey.fileSizeKey`), not
    /// `totalFileAllocatedSize`. Block-allocation on iOS APFS can report a
    /// different value for newly-written blobs right after a `URLSession`
    /// stream finishes (esp. multi-GB safetensors), which would falsely fail
    /// the exact-size check against the HF tree API.
    private static func resolvedFileByteSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isRegularFile == true || values.isSymbolicLink == true else {
            return 0
        }
        if values.isSymbolicLink == true {
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) else { return 0 }
            let destURL: URL
            if (dest as NSString).isAbsolutePath {
                destURL = URL(fileURLWithPath: dest)
            } else {
                destURL = url.deletingLastPathComponent().appendingPathComponent(dest)
            }
            return logicalFileByteSize(destURL)
        }
        return logicalFileByteSize(url)
    }

    /// Logical byte length of a regular file (the size HF reports).
    private static func logicalFileByteSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize
        else { return 0 }
        return Int64(size)
    }

    /// Parse catalog `approxSize` strings like `~5.2 GB` / `~800 MB` into bytes.
    private static func approxBytesFromCatalog(modelID: String) -> Int64? {
        let lower = modelID.lowercased()
        let hit = LocalMetalCatalog.recommended.first {
            $0.hubID == modelID || $0.hubID.lowercased() == lower
        } ?? LocalMetalCatalog.registry.first {
            $0.hubID == modelID || $0.hubID.lowercased() == lower
        }
        return parseApproxSizeBytes(hit?.approxSize)
    }

    private static func parseApproxSizeBytes(_ raw: String?) -> Int64? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        if s.hasPrefix("~") { s = String(s.dropFirst()) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let numberPart = s.prefix(while: { $0.isNumber || $0 == "." || $0 == "," })
        let unitPart = s.dropFirst(numberPart.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = numberPart.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        if unitPart.hasPrefix("GB") || unitPart.hasPrefix("G") {
            return Int64(value * 1_000_000_000) // decimal GB as HF often reports
        }
        if unitPart.hasPrefix("MB") || unitPart.hasPrefix("M") {
            return Int64(value * 1_000_000)
        }
        if unitPart.hasPrefix("KB") || unitPart.hasPrefix("K") {
            return Int64(value * 1_000)
        }
        return nil
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

    /// Poll cache + large temp files + last hub Progress at ~2.5 Hz.
    private static func startDiskPoll(broker: DownloadProgressBroker, repoDir: URL) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let cacheBytes = Self.directoryByteSize(at: repoDir)
                let tempBytes = Self.largeTempFileBytes()
                await broker.noteObservedBytes(
                    cacheBytes: cacheBytes,
                    tempBytes: tempBytes,
                    status: "Downloading…"
                )
                await broker.rescanHubProgress()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
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
            // Prefer the in-memory raw bytes (set by the VM via the
            // jpegData-init convenience) — avoids a base64 round-trip per
            // photo. Fall back to decoding the base64 wire string for
            // transcripts replayed from disk.
            let data = attachment.bytes
            guard !data.isEmpty else {
                throw ProviderError.transport("Could not decode the captured photo for on-device vision.")
            }
            // Fast path: CIImage handles most JPEGs without ever materializing
            // a full UIImage bitmap (which doubles RAM during decode).
            if let ciImage = CIImage(data: data) {
                return .ciImage(ciImage)
            }
            // CIImage rejects some HEIC + awkward-EXIF photos. Fall back to a
            // CGImageSource-backed CGImage (still single-decode) before we
            // resort to a full UIImage decode + JPEG re-encode, which is the
            // most expensive path and the one most likely to OOM next to a
            // resident VLM.
            #if canImport(ImageIO)
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
               ] as CFDictionary)
            {
                return .ciImage(CIImage(cgImage: cgImage))
            }
            #endif
            #if canImport(UIKit)
            if let ui = UIImage(data: data),
               let jpeg = ui.jpegData(compressionQuality: 0.9),
               let ci = CIImage(data: jpeg) {
                return .ciImage(ci)
            }
            #endif
            throw ProviderError.transport("Could not decode the captured photo for on-device vision.")
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
///
/// Emits are throttled (~4/s, MB-granular) so multi‑GB models do not flood the
/// main actor / SwiftUI and freeze the phone.
private actor DownloadProgressBroker {
    private let emit: @Sendable (LocalMetalDownloadProgress) -> Void
    private var bestFraction: Double = 0
    private var expectedBytes: Int64 = 0
    private var lastEmitted: Double = -1
    private var lastStatusKey = ""
    private var lastPublishAt: ContinuousClock.Instant?
    private var tempBaseline: Int64 = 0
    private var status: String = "Downloading weights…"
    private var currentFile: String?
    private var bytesDownloaded: Int64 = 0
    /// Snapshot of the last hub Progress (unit counts only — avoid re-entering Progress).
    private var lastHubCompleted: Int64 = 0
    private var lastHubTotal: Int64 = 0
    private var lastHubFraction: Double = 0
    private var lastHubStatus: String?
    private var lastHubFile: String?

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
        // Snapshot counts immediately; do not retain Progress across awaits.
        let completed = progress.completedUnitCount
        let total = progress.totalUnitCount
        let hierarchical = progress.fractionCompleted
        let label = Self.statusLabel(from: progress)
        let file = Self.fileLabel(from: progress)

        lastHubCompleted = max(lastHubCompleted, completed)
        if total > 0 {
            lastHubTotal = max(lastHubTotal, total)
        }
        if hierarchical.isFinite, hierarchical > 0 {
            lastHubFraction = max(lastHubFraction, hierarchical)
        }
        if let label { lastHubStatus = label; status = label }
        if let file { lastHubFile = file; currentFile = file }

        if total > 1_024 {
            expectedBytes = max(expectedBytes, total)
        }
        if total > 1_024 * 1_024, completed >= 0 {
            bytesDownloaded = max(bytesDownloaded, completed)
            expectedBytes = max(expectedBytes, total)
        }
        raise(Self.fraction(completed: completed, total: total, hierarchical: hierarchical))
    }

    /// Re-apply the last hub snapshot between disk polls.
    func rescanHubProgress() {
        if let label = lastHubStatus { status = label }
        if let file = lastHubFile { currentFile = file }
        raise(Self.fraction(
            completed: lastHubCompleted,
            total: lastHubTotal,
            hierarchical: lastHubFraction
        ))
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
        if clamped > bestFraction {
            bestFraction = clamped
        }
        publish(bestFraction, force: false)
    }

    private func publish(_ raw: Double, force: Bool) {
        let value = min(1, max(0, raw))
        // MB-granular key so multi‑GB byte ticks do not emit every kilobyte.
        let mbDown = bytesDownloaded / 1_048_576
        let mbTotal = expectedBytes / 1_048_576
        let statusKey = "\(status)|\(currentFile ?? "")|\(mbDown)|\(mbTotal)|\(Int(value * 200))"
        let now = ContinuousClock.now
        let minInterval: Duration = .milliseconds(250)
        let timeOK: Bool = {
            guard let last = lastPublishAt else { return true }
            return now - last >= minInterval
        }()
        // ~0.5% steps + status/file/MB changes, rate-limited to ~4 UI updates/sec.
        let fractionMoved = value >= 1 || value >= lastEmitted + 0.005 || lastEmitted < 0
        let statusMoved = statusKey != lastStatusKey
        guard force || ((fractionMoved || statusMoved) && timeOK) || (value >= 1 && lastEmitted < 1) else {
            return
        }
        lastEmitted = value
        lastStatusKey = statusKey
        lastPublishAt = now

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
        fraction(
            completed: progress.completedUnitCount,
            total: progress.totalUnitCount,
            hierarchical: progress.fractionCompleted
        )
    }

    static func fraction(completed: Int64, total: Int64, hierarchical: Double) -> Double {
        if hierarchical.isFinite, hierarchical > 0 {
            return min(0.99, max(0, hierarchical))
        }
        if total > 0, completed > 0 {
            return min(0.99, max(0, Double(completed) / Double(total)))
        }
        if completed > 0 {
            return min(0.99, Double(completed) / 4_000_000_000)
        }
        return 0
    }

    /// Human step label from Foundation Progress (file counts only — never raw byte “0 of N”).
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
        // Skip Foundation’s default “0 of 5,179,239,349” byte strings.
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

/// Single-bool flag actor used to gate memory-pressure eviction. Held by
/// the engine so the warning observer can ask whether a multi-GB load is
/// currently in flight before unloading weights.
private actor LoadFlag {
    private var value = false
    func set(_ newValue: Bool) { value = newValue }
    func get() -> Bool { value }
}

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
    /// Prefer the canonical `RoamSocket` tree so downloads match
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
