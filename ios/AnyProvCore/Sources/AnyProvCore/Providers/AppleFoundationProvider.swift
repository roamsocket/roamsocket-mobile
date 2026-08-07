import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Chat-only access to Apple’s on-device Foundation Model (Apple Intelligence).
///
/// Uses the system language model via the FoundationModels framework when
/// available (iOS 26+ / macOS 26+ with Apple Intelligence enabled). Coding
/// sessions never use this provider (`supportsCodingAgent == false`).
///
/// No API key is required. When the model is unavailable, listing fails with a
/// clear reason so the model picker can surface it under this provider section.
public struct AppleFoundationProvider: ModelProvider {
    public let id: ProviderID = .appleFoundation

    /// Stable wire id for the built-in system model.
    public static let systemModelID = "system"

    /// Friendly name shown in the model picker / composer pill.
    public static let systemDisplayName = "Apple Intelligence"

    /// Approximate context budget for the on-device model (conservative).
    public static let approximateContextWindow = 4_096

    public init() {}

    public func listModels(apiKey: String) async throws -> [AIModel] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            try Self.ensureAvailable()
            return [
                AIModel(
                    provider: .appleFoundation,
                    modelID: Self.systemModelID,
                    displayName: Self.systemDisplayName,
                    contextWindow: Self.approximateContextWindow
                )
            ]
        }
        #endif
        throw ProviderError.transport(
            "Apple Intelligence requires iOS 26+ (or macOS 26+) with Apple Intelligence enabled."
        )
    }

    public func chat(
        model: String,
        apiKey: String,
        messages: [ProviderChatMessage],
        effort: Effort?
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return try await Self.generate(messages: messages, effort: effort)
        }
        #endif
        throw ProviderError.transport(
            "Apple Intelligence requires iOS 26+ (or macOS 26+) with Apple Intelligence enabled."
        )
    }

    // MARK: - Foundation Models

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func ensureAvailable() throws {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw ProviderError.transport(unavailableMessage(for: reason))
        @unknown default:
            guard model.isAvailable else {
                throw ProviderError.transport(
                    "Apple Intelligence is not available on this device."
                )
            }
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func unavailableMessage(
        for reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to use the on-device model."
        case .modelNotReady:
            return "Apple Intelligence is still downloading or preparing. Try again in a moment."
        @unknown default:
            return "Apple Intelligence is not available right now (\(String(describing: reason)))."
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func generate(
        messages: [ProviderChatMessage],
        effort: Effort?
    ) async throws -> String {
        try ensureAvailable()

        if messages.contains(where: \.hasImages) {
            throw ProviderError.transport(
                "Apple Intelligence chat is text-only. Remove attached images or pick a vision model."
            )
        }

        let systemParts = messages
            .filter { $0.role == .system }
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let turns = messages.filter { $0.role != .system }
        guard let last = turns.last else {
            throw ProviderError.transport("No user message to send to Apple Intelligence.")
        }

        let defaultInstructions = """
        You are a helpful assistant in CodeSocket, a coding and chat app.
        Be clear and concise. Prefer practical answers for software tasks.
        """
        let instructions: String
        if systemParts.isEmpty {
            instructions = defaultInstructions
        } else {
            instructions = systemParts.joined(separator: "\n\n")
        }

        let prompt = buildPrompt(turns: turns, last: last)
        let options = generationOptions(effort: effort)

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, options: options)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw ProviderError.transport("Apple Intelligence returned an empty reply.")
            }
            return text
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.transport(
                "Apple Intelligence failed: \(error.localizedDescription)"
            )
        }
    }

    /// Build a single prompt that includes prior turns so the one-shot session
    /// still sees multi-turn context (session transcript is not persisted).
    @available(iOS 26.0, macOS 26.0, *)
    private static func buildPrompt(
        turns: [ProviderChatMessage],
        last: ProviderChatMessage
    ) -> String {
        let history = turns.dropLast()
        if history.isEmpty {
            return clip(last.content, limit: 12_000)
        }

        var lines: [String] = []
        lines.append("Conversation so far:")
        for turn in history {
            let role: String
            switch turn.role {
            case .user: role = "User"
            case .assistant: role = "Assistant"
            case .system: role = "System"
            }
            lines.append("\(role): \(clip(turn.content, limit: 3_000))")
        }
        lines.append("")
        lines.append("User: \(clip(last.content, limit: 8_000))")
        lines.append("")
        lines.append("Assistant:")
        return lines.joined(separator: "\n")
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func generationOptions(effort: Effort?) -> GenerationOptions {
        let maxTokens: Int
        let temperature: Double
        switch effort ?? .high {
        case .low:
            maxTokens = 512
            temperature = 0.3
        case .medium:
            maxTokens = 1_024
            temperature = 0.5
        case .high:
            maxTokens = 2_048
            temperature = 0.7
        }
        return GenerationOptions(
            sampling: .greedy,
            temperature: temperature,
            maximumResponseTokens: maxTokens
        )
    }
    #endif

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
