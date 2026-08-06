import Foundation

/// Chat-only on-device inference via Metal (MLX).
///
/// Listing scans `LocalMetalModelStore` for downloaded / bundled weights.
/// Generation is delegated to a process-wide engine registered by the app
/// (`LocalMetalRuntime.register`). The desktop coding agent never uses this
/// provider (`supportsCodingAgent == false`).
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
                "On-device Metal runtime is not ready. Open Settings → On-device (Metal) and download a model."
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
}

/// Process-wide hook so AnyProvCore stays free of the heavy MLX dependency graph.
public enum LocalMetalRuntime {
    public static var engine: (any LocalMetalGenerating)?
}

// MARK: - Model inventory

/// Discovers on-device model folders under Application Support.
public actor LocalMetalModelStore {
    public static let shared = LocalMetalModelStore()

    /// Hugging Face-style model ids the user can enable (downloaded on demand by the engine).
    public static let catalogPresets: [(id: String, name: String)] = [
        ("mlx-community/Llama-3.2-1B-Instruct-4bit", "Llama 3.2 1B (4-bit)"),
        ("mlx-community/Llama-3.2-3B-Instruct-4bit", "Llama 3.2 3B (4-bit)"),
        ("mlx-community/Qwen2.5-1.5B-Instruct-4bit", "Qwen 2.5 1.5B (4-bit)"),
        ("mlx-community/gemma-2-2b-it-4bit", "Gemma 2 2B (4-bit)"),
        ("mlx-community/Phi-3.5-mini-instruct-4bit", "Phi 3.5 Mini (4-bit)"),
    ]

    private let defaultsKey = "localMetal.enabledModelIDs.v1"

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

    public func enabledModelIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    public func setEnabled(_ enabled: Bool, modelID: String) {
        var set = Set(enabledModelIDs())
        if enabled { set.insert(modelID) } else { set.remove(modelID) }
        UserDefaults.standard.set(Array(set).sorted(), forKey: defaultsKey)
    }

    public func listModels() async -> [AIModel] {
        var out: [AIModel] = []
        let enabled = Set(enabledModelIDs())

        // Enabled catalog presets always appear (engine downloads weights on first use).
        for preset in Self.catalogPresets where enabled.contains(preset.id) {
            out.append(AIModel(
                provider: .localMetal,
                modelID: preset.id,
                displayName: preset.name + " · Metal",
                contextWindow: 8192
            ))
        }

        // Local folders (user-copied MLX trees) also appear.
        if let dir = try? modelsDirectory(),
           let kids = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
           ) {
            for url in kids {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue
                else { continue }
                let id = "local/\(url.lastPathComponent)"
                if out.contains(where: { $0.modelID == id }) { continue }
                out.append(AIModel(
                    provider: .localMetal,
                    modelID: id,
                    displayName: url.lastPathComponent + " · Metal",
                    contextWindow: nil
                ))
            }
        }

        // If nothing enabled yet, still surface presets as discoverable (disabled until toggled).
        // Catalog only returns enabled/local folders so the picker stays clean.
        if out.isEmpty {
            // Show first preset as a hint model when nothing is installed — still needs enable.
            // Return empty; Settings UI lists presets for opt-in.
        }
        return out
    }
}
