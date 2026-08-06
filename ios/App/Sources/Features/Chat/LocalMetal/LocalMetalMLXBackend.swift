import Foundation
import AnyProvCore
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Real Metal-backed chat engine using mlx-swift-lm + Hugging Face hub.
///
/// **Chat only** — coding sessions never select `ProviderID.localMetal`.
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
    /// Cache loaded containers by model id (weights are large; reuse across turns).
    private let lock = NSLock()
    private var containers: [String: ModelContainer] = [:]

    func generate(
        modelID: String,
        messages: [ProviderChatMessage],
        effort: Effort?
    ) async throws -> String {
        let container = try await loadContainer(id: modelID)
        let params = generateParameters(effort: effort)

        // System prompt as ChatSession instructions; remaining turns as history + prompt.
        let systemText = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let conversation = messages.filter { $0.role != .system }

        guard let last = conversation.last else {
            throw ProviderError.transport("Nothing to generate — empty conversation.")
        }

        let history: [Chat.Message] = conversation.dropLast().map { turn in
            switch turn.role {
            case .user: return .user(turn.content)
            case .assistant: return .assistant(turn.content)
            case .system: return .system(turn.content)
            }
        }

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
            let prompt: String
            switch last.role {
            case .user:
                prompt = last.content
            case .assistant, .system:
                // Unusual: last message isn't user — feed full transcript once.
                let all: [Chat.Message] = conversation.map { turn in
                    switch turn.role {
                    case .user: return .user(turn.content)
                    case .assistant: return .assistant(turn.content)
                    case .system: return .system(turn.content)
                    }
                }
                let output = try await session.respond(to: all)
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw ProviderError.transport("Model returned an empty response.")
                }
                return trimmed
            }

            let output = try await session.respond(to: prompt)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ProviderError.transport("Model returned an empty response.")
            }
            return trimmed
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport(
                "Metal generation failed: \(error.localizedDescription)"
            )
        }
    }

    private func loadContainer(id: String) async throws -> ModelContainer {
        lock.lock()
        if let cached = containers[id] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Strip local/ prefix — those are folder names under Application Support.
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
            // Macro expands to hub downloader + HF tokenizer loader (mlx-swift-lm 3.x).
            let container = try await #huggingFaceLoadModelContainer(
                configuration: configuration
            )
            lock.lock()
            containers[id] = container
            lock.unlock()
            return container
        } catch {
            throw ProviderError.transport(
                "Failed to load on-device model “\(id)”: \(error.localizedDescription). " +
                "Check network for the first download, then retry offline."
            )
        }
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
