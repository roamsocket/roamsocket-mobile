import Foundation
import AnyProvCore

/// Heuristics for models that accept image inputs (Vision mode).
enum VisionCapability {
    /// Whether this catalog model is likely to accept multimodal (image + text) turns.
    static func supportsVision(_ model: AIModel) -> Bool {
        // Google chat is not wired in the iOS client yet.
        if model.provider == .google { return false }

        // On-device Metal VLMs (Gemma 4, Qwen-VL, SmolVLM, …).
        if model.provider == .localMetal {
            return isLikelyLocalVLM(model.modelID)
        }

        let id = model.modelID.lowercased()

        // Explicit non-vision families.
        if id.contains("whisper")
            || id.contains("embed")
            || id.contains("tts")
            || id.contains("moderation")
            || id.contains("transcri")
            || id.contains("dall-e")
            || id.contains("tts-")
            || id.contains("realtime")
        {
            return false
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

        return false
    }

    /// Short chip label for list rows.
    static func visionBadgeLabel(for model: AIModel) -> String? {
        supportsVision(model) ? "Vision" : nil
    }

    /// Prefer a known vision model, else the first vision-capable entry, else nil.
    static func preferredVisionModel(from models: [AIModel], current: AIModel?) -> AIModel? {
        if let current, supportsVision(current) { return current }
        let vision = models.filter(supportsVision)
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
        let id = modelID.lowercased()
        if id.contains("whisper") || id.contains("embed") || id.contains("tts") {
            return false
        }
        // Explicit text-only Gemma 3n LM builds.
        if id.contains("gemma-3n") && id.contains("-lm-") { return false }
        if id.contains("gemma3_text") { return false }

        if id.contains("gemma-4") || id.contains("gemma4") { return true }
        if id.contains("gemma-3-4b") || id.contains("gemma-3-12b") || id.contains("gemma-3-27b") {
            return true
        }
        // Multimodal Gemma 3n (non-lm) weights.
        if id.contains("gemma-3n") { return true }

        if id.contains("paligemma")
            || id.contains("smolvlm")
            || id.contains("fastvlm")
            || id.contains("pixtral")
            || id.contains("llava")
            || id.contains("moondream")
            || id.contains("paddleocr")
            || id.contains("kimi-vl")
            || id.contains("mage-vl")
        {
            return true
        }
        if id.contains("qwen2-vl")
            || id.contains("qwen2.5-vl")
            || id.contains("qwen3-vl")
            || id.contains("qwen2_vl")
            || id.contains("qwen2_5_vl")
            || id.contains("qwen3_vl")
        {
            return true
        }
        if id.contains("lfm2-vl") || id.contains("lfm2.5-vl") { return true }
        if id.contains("ministral-3") { return true }
        if id.contains("vision") || id.contains("vlm") { return true }
        // Generic VL token in id (avoid matching "vl" inside unrelated names carefully).
        if id.contains("-vl-") || id.contains("_vl_") || id.contains("-vl_")
            || id.hasSuffix("-vl") || id.contains("/vl-")
        {
            return true
        }
        return false
    }
}
