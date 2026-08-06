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

        let container = try await loadContainer(id: modelID, progress: { _ in })
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
        // Load container downloads hub weights into our app-scoped cache.
        _ = try await loadContainer(id: modelID) { fraction in
            progress(fraction)
        }
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
            return
        }

        guard let repoID = Repo.ID(rawValue: modelID) else {
            throw ProviderError.transport("Invalid model id “\(modelID)”.")
        }
        let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        if FileManager.default.fileExists(atPath: repoDir.path) {
            try FileManager.default.removeItem(at: repoDir)
        }
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
                return hasModelWeights(at: folder)
            }
            return false
        }
        guard let repoID = Repo.ID(rawValue: modelID) else { return false }
        let repoDir = hubCache.repoDirectory(repo: repoID, kind: .model)
        return hasModelWeights(at: repoDir)
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
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
        if let cached = await cache.get(id) {
            progress(1)
            return cached
        }

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

        do {
            // Explicit hub client so weights land in Application Support (deletable).
            let container = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(hubClient),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { p in
                    let fraction: Double
                    if p.totalUnitCount > 0 {
                        fraction = min(1, max(0, p.fractionCompleted))
                    } else if p.completedUnitCount > 0 {
                        fraction = min(0.99, Double(p.completedUnitCount) / 1_000_000_000)
                    } else {
                        fraction = 0
                    }
                    progress(fraction)
                }
            )
            await cache.set(id, container)
            return container
        } catch {
            throw ProviderError.transport(
                "Failed to load on-device model “\(id)”: \(error.localizedDescription). " +
                "Check network for the download, then retry. Models are not bundled in the app."
            )
        }
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

    private func hasModelWeights(at root: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else { return false }
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

// MARK: - Container cache

private actor ContainerCache {
    private var containers: [String: ModelContainer] = [:]

    func get(_ id: String) -> ModelContainer? { containers[id] }

    func set(_ id: String, _ container: ModelContainer) {
        containers[id] = container
    }

    func remove(_ id: String) {
        containers.removeValue(forKey: id)
    }

    func removeAll() {
        containers.removeAll()
    }

    func ids() -> [String] {
        Array(containers.keys).sorted()
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
