import Foundation
import AnyProvCore

/// Heuristics for models that accept image inputs (Vision mode).
enum VisionCapability {
    /// Whether this catalog model is likely to accept multimodal (image + text) turns.
    ///
    /// - Parameter providerMarkedVisionCapable: When true (custom provider toggle),
    ///   every non-excluded model from that provider is treated as vision-capable.
    static func supportsVision(
        _ model: AIModel,
        providerMarkedVisionCapable: Bool = false
    ) -> Bool {
        // Google chat is not wired in the iOS client yet.
        if model.provider == .google { return false }

        // Apple Foundation Model is text-only in this client.
        if model.provider == .appleFoundation { return false }

        // On-device Metal VLMs (Gemma 4, Qwen-VL, SmolVLM, …).
        // Prefer catalog Vision tags + shared hub-id heuristics so downloads
        // marked Vision in Settings always appear in Vision mode.
        if model.provider == .localMetal {
            return isLikelyLocalVLM(model.modelID)
        }

        let id = model.modelID.lowercased()

        // Explicit non-vision families (even when the provider is marked vision).
        if isClearlyNonVisionModelID(id) {
            return false
        }

        // Custom providers the user marked as vision-capable (Ollama VLMs, proxies, …).
        if providerMarkedVisionCapable {
            return true
        }

        // Explicit vision / multimodal markers.
        if id.contains("vision")
            || id.contains("-vl")
            || id.contains("vl-")
            || id.contains("vlm")
            || id.contains("pixtral")
            || id.contains("llava")
            || id.contains("moondream")
            || id.contains("qwen2-vl")
            || id.contains("qwen2.5-vl")
            || id.contains("qwen3-vl")
            || id.contains("qwen-vl")
            || id.contains("gemini")
            || id.contains("gpt-4o")
            || id.contains("gpt-4.1")
            || id.contains("gpt-4-turbo")
            || id.contains("gpt-4-vision")
            || id.contains("chatgpt-4o")
            || id.contains("gpt-5")
            || id.contains("claude-3")
            || id.contains("claude-4")
            || id.contains("claude-5")
            || id.contains("claude-fable")
            || id.contains("claude-sonnet")
            || id.contains("claude-opus")
            || id.contains("claude-haiku")
            || id.contains("grok-2-vision")
            || id.contains("grok-vision")
            || id.contains("grok-4")
            || (id.contains("llama-3.2") && id.contains("vision"))
            || id.contains("llama-4")
            || id.contains("gemma-4")
            || id.contains("gemma4")
        {
            return true
        }

        // Modern Anthropic catalog models are multimodal.
        if model.provider == .anthropic {
            return id.contains("claude")
        }

        // OpenAI flagships (and o-series) accept images.
        if model.provider == .openai {
            if id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") { return true }
            if id.contains("gpt-4") || id.contains("gpt-5") { return true }
        }

        // xAI Grok multimodal family (Grok 4 / 4.x accept image input).
        if model.provider == .xai {
            if id.contains("grok") && !id.contains("text") && !id.contains("imagine") {
                return true
            }
        }

        // MiniMax-M3 accepts image (and video) input via OpenAI-compatible parts.
        if model.provider == .minimax {
            return id.contains("minimax-m3")
        }

        return false
    }

    /// Model ids that never accept images (embeddings, audio, image-gen, …).
    static func isClearlyNonVisionModelID(_ id: String) -> Bool {
        id.contains("whisper")
            || id.contains("embed")
            || id.contains("tts")
            || id.contains("moderation")
            || id.contains("transcri")
            || id.contains("dall-e")
            || id.contains("tts-")
            || id.contains("realtime")
            || id.contains("text-embedding")
            || id.contains("rerank")
    }

    /// Short chip label for list rows.
    static func visionBadgeLabel(
        for model: AIModel,
        providerMarkedVisionCapable: Bool = false
    ) -> String? {
        supportsVision(model, providerMarkedVisionCapable: providerMarkedVisionCapable)
            ? "Vision"
            : nil
    }

    /// Prefer a known vision model, else the first vision-capable entry, else nil.
    /// - Parameter isVision: Override for custom-provider vision flags (defaults to name heuristics).
    static func preferredVisionModel(
        from models: [AIModel],
        current: AIModel?,
        isVision: (AIModel) -> Bool = { supportsVision($0) }
    ) -> AIModel? {
        if let current, isVision(current) { return current }
        let vision = models.filter(isVision)
        let preferredIDs = [
            // On-device (phone-first)
            "gemma-4-e2b", "gemma-4-e4b", "gemma-4-12b",
            "qwen3-vl-2b", "qwen3-vl-4b", "qwen2.5-vl-3b", "qwen2-vl-2b",
            "lfm2.5-vl", "lfm2-vl", "smolvlm2", "smolvlm", "paddleocr", "fastvlm",
            // Cloud
            "gpt-5", "gpt-4o", "gpt-4.1", "claude-sonnet-5", "claude-opus",
            "claude-sonnet", "grok-4", "grok-2-vision", "pixtral",
        ]
        for needle in preferredIDs {
            if let match = vision.first(where: { $0.modelID.lowercased().contains(needle) }) {
                return match
            }
        }
        return vision.first
    }

    /// Hub-id heuristics for Apple Silicon / MLX vision-language models.
    static func isLikelyLocalVLM(_ modelID: String) -> Bool {
        LocalMetalCatalog.isLikelyVisionHubID(modelID)
    }
}
